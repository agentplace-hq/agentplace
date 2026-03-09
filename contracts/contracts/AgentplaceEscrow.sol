// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract AgentplaceEscrow is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    IERC20 public immutable usdc;
    address public clearinghouse;
    address public judgeAddress;
    uint256 public feeBps = 25; // 0.25%

    enum TaskStatus { Empty, Escrowed, Completed, Disputed, Refunded, TimedOut }

    struct Task {
        address buyer;
        address seller;
        uint256 amount;
        bytes32 taskHash;
        TaskStatus status;
        uint256 timeoutAt;
    }

    mapping(bytes32 => Task) public tasks;

    event FundsLocked(bytes32 indexed taskId, address indexed buyer, address indexed seller, uint256 amount);
    event FundsReleased(bytes32 indexed taskId, address indexed seller, uint256 sellerAmount, uint256 fee);
    event DisputeFlagged(bytes32 indexed taskId, address indexed buyer);
    event DisputeResolved(bytes32 indexed taskId, bool favorBuyer);
    event FundsRefunded(bytes32 indexed taskId, address indexed recipient, uint256 amount);

    error TaskAlreadyExists();
    error InvalidSeller();
    error InvalidAmount();
    error TimeoutOutOfRange();
    error InvalidSignature();
    error TimeoutNotReached();
    error TimeoutAlreadyReached();
    error Unauthorized();
    error FeeExceedsMax();
    error InvalidStatus();

    constructor(
        address _usdc,
        address _clearinghouse,
        address _judge
    ) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
        clearinghouse = _clearinghouse;
        judgeAddress = _judge;
    }

    // ── Core flow ────────────────────────────────────────────────────────────

    /**
     * @notice Buyer calls this directly to lock USDC in escrow.
     * msg.sender becomes task.buyer — clearinghouse never holds buyer funds.
     */
    function lockFunds(
        bytes32 taskId,
        address seller,
        uint256 amount,
        uint256 timeoutSeconds,
        bytes32 taskHash
    ) external nonReentrant {
        if (tasks[taskId].status != TaskStatus.Empty) revert TaskAlreadyExists();
        if (seller == address(0) || seller == msg.sender) revert InvalidSeller();
        if (amount == 0) revert InvalidAmount();
        if (timeoutSeconds < 30 || timeoutSeconds > 86400) revert TimeoutOutOfRange();

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        tasks[taskId] = Task({
            buyer: msg.sender,
            seller: seller,
            amount: amount,
            taskHash: taskHash,
            status: TaskStatus.Escrowed,
            timeoutAt: block.timestamp + timeoutSeconds
        });

        emit FundsLocked(taskId, msg.sender, seller, amount);
    }

    /**
     * @notice Release escrowed funds to seller.
     * Requires a valid buyer signature over (taskId, chainId, address(this)).
     * Anyone may call — clearinghouse typically relays this to pay gas.
     *
     * 0.B7: digest now includes block.chainid and address(this) to prevent
     * cross-chain and cross-contract signature replay.
     */
    function releaseToSeller(
        bytes32 taskId,
        bytes calldata buyerSignature
    ) external nonReentrant {
        Task storage task = tasks[taskId];
        if (task.status != TaskStatus.Escrowed) revert InvalidStatus();

        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encodePacked(taskId, block.chainid, address(this)))
        );
        if (digest.recover(buyerSignature) != task.buyer) revert InvalidSignature();

        _release(taskId, task);
    }

    /**
     * @notice Buyer flags a dispute directly on-chain.
     */
    function flagDispute(bytes32 taskId) external nonReentrant {
        Task storage task = tasks[taskId];
        if (task.status != TaskStatus.Escrowed) revert InvalidStatus();
        if (msg.sender != task.buyer) revert Unauthorized();
        if (block.timestamp >= task.timeoutAt) revert TimeoutAlreadyReached();

        task.status = TaskStatus.Disputed;
        emit DisputeFlagged(taskId, msg.sender);
    }

    /**
     * @notice Clearinghouse relays a buyer's dispute flag with the buyer's
     * authorizing signature. Allows server-side dispute routing without
     * requiring the buyer to submit a transaction directly.
     *
     * Buyer signs: keccak256(abi.encodePacked(taskId, "DISPUTE", block.chainid, address(this)))
     */
    function flagDisputeRelayed(
        bytes32 taskId,
        bytes calldata buyerSignature
    ) external nonReentrant {
        Task storage task = tasks[taskId];
        if (task.status != TaskStatus.Escrowed) revert InvalidStatus();
        if (block.timestamp >= task.timeoutAt) revert TimeoutAlreadyReached();

        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encodePacked(taskId, "DISPUTE", block.chainid, address(this)))
        );
        if (digest.recover(buyerSignature) != task.buyer) revert InvalidSignature();

        task.status = TaskStatus.Disputed;
        emit DisputeFlagged(taskId, task.buyer);
    }

    /**
     * @notice Judge resolves a disputed task.
     *
     * 0.B7: judge signature payload now includes block.chainid and address(this).
     */
    function resolveDispute(
        bytes32 taskId,
        bool favorBuyer,
        bytes calldata judgeSignature
    ) external nonReentrant {
        Task storage task = tasks[taskId];
        if (task.status != TaskStatus.Disputed) revert InvalidStatus();

        bytes32 payload = keccak256(abi.encodePacked(taskId, favorBuyer, block.chainid, address(this)));
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(payload);
        if (digest.recover(judgeSignature) != judgeAddress) revert InvalidSignature();

        if (favorBuyer) {
            task.status = TaskStatus.Refunded;
            usdc.safeTransfer(task.buyer, task.amount);
            emit FundsRefunded(taskId, task.buyer, task.amount);
        } else {
            _release(taskId, task);
        }

        emit DisputeResolved(taskId, favorBuyer);
    }

    /**
     * @notice Anyone can claim a timeout refund after the timeout period.
     * Funds always go to task.buyer — there is no risk in allowing any
     * address to trigger this neutral, buyer-benefiting action.
     *
     * 0.B8: removed the `msg.sender == task.buyer` restriction so the
     * clearinghouse escrow monitor can reclaim on behalf of buyers.
     */
    function claimTimeout(bytes32 taskId) external nonReentrant {
        Task storage task = tasks[taskId];
        if (task.status != TaskStatus.Escrowed) revert InvalidStatus();
        if (block.timestamp < task.timeoutAt) revert TimeoutNotReached();

        task.status = TaskStatus.TimedOut;
        usdc.safeTransfer(task.buyer, task.amount);
        emit FundsRefunded(taskId, task.buyer, task.amount);
    }

    // ── Internal ─────────────────────────────────────────────────────────────

    function _release(bytes32 taskId, Task storage task) internal {
        uint256 fee = (task.amount * feeBps) / 10000;
        uint256 sellerAmount = task.amount - fee;
        task.status = TaskStatus.Completed;

        usdc.safeTransfer(task.seller, sellerAmount);
        if (fee > 0) usdc.safeTransfer(clearinghouse, fee);

        emit FundsReleased(taskId, task.seller, sellerAmount, fee);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setJudge(address newJudge) external onlyOwner {
        judgeAddress = newJudge;
    }

    function setClearinghouse(address newClearinghouse) external onlyOwner {
        clearinghouse = newClearinghouse;
    }

    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > 100) revert FeeExceedsMax();
        feeBps = newFeeBps;
    }
}
