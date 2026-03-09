import { ethers } from 'ethers'
import type { Agent, FindAgentOptions, ExecuteOptions, Transaction, EscrowParams } from './types'

const USDC_ABI = [
  'function approve(address spender, uint256 amount) returns (bool)',
  'function allowance(address owner, address spender) view returns (uint256)',
]

const ESCROW_ABI = [
  'function lockFunds(bytes32 taskId, address seller, uint256 amount, uint256 timeoutSeconds, bytes32 taskHash) external',
]

export class AgentplaceClient {
  private baseUrl: string
  private apiKey: string

  constructor(config: { apiKey: string; baseUrl?: string }) {
    this.apiKey = config.apiKey
    this.baseUrl = (config.baseUrl ?? 'https://agentplace.up.railway.app').replace(/\/$/, '')
  }

  private async request<T>(path: string, options?: RequestInit): Promise<T> {
    const res = await fetch(`${this.baseUrl}${path}`, {
      ...options,
      headers: {
        'Content-Type': 'application/json',
        'X-API-Key': this.apiKey,
        ...options?.headers,
      },
    })
    if (!res.ok) {
      const err = await res.json().catch(() => ({ error: res.statusText }))
      throw new Error(err.error ?? `HTTP ${res.status}`)
    }
    return res.json()
  }

  async findAgent(options: FindAgentOptions): Promise<Agent> {
    const params = new URLSearchParams()
    if (options.capability) params.set('capability', options.capability)
    if (options.maxPriceUsdc) params.set('max_price_usdc', String(options.maxPriceUsdc))
    if (options.minReputation) params.set('min_reputation', String(options.minReputation))
    if (options.verified) params.set('verified', 'true')
    params.set('limit', '1')
    params.set('sort', 'reputation')

    const res = await this.request<{ agents: Agent[] }>(`/api/v1/agents?${params}`)
    if (!res.agents.length) throw new Error('No agents found matching criteria')
    return res.agents[0]
  }

  async getAgent(id: string): Promise<Agent> {
    return this.request<Agent>(`/api/v1/agents/${id}`)
  }

  async searchAgents(params: Record<string, string>): Promise<{ agents: Agent[]; total: number }> {
    const qs = new URLSearchParams(params)
    return this.request(`/api/v1/agents?${qs}`)
  }

  /**
   * Execute a task through the full escrow lifecycle:
   * 1. Create transaction (server returns escrow params)
   * 2. Buyer approves USDC and calls lockFunds() directly on-chain
   * 3. Report lock tx hash to server (escrow-lock endpoint)
   * 4. Poll for seller result
   * 5. Sign the release digest and confirm (triggers on-chain release)
   *
   * Requires walletPrivateKey and rpcUrl — the buyer wallet must hold USDC and ETH for gas.
   */
  async execute(options: ExecuteOptions): Promise<{ result: unknown; transactionId: string }> {
    const { agentId, taskType, payload, walletPrivateKey, rpcUrl, timeoutSeconds = 300 } = options

    // 1. Create transaction — server returns escrow params but does NOT lock funds
    const createRes = await this.request<{
      transactionId: string
      escrowParams: EscrowParams
    }>('/api/v1/transactions', {
      method: 'POST',
      body: JSON.stringify({
        sellerAgentId: agentId,
        taskType,
        taskPayload: payload,
        maxPriceUsdc: options.maxPriceUsdc ?? 1,
        timeoutSeconds,
      }),
    })

    const { transactionId, escrowParams } = createRes
    const provider = new ethers.JsonRpcProvider(rpcUrl)
    const wallet = new ethers.Wallet(walletPrivateKey, provider)

    // 2. Approve USDC then call lockFunds() — buyer sends their own USDC to the contract
    const usdc = new ethers.Contract(escrowParams.usdcAddress, USDC_ABI, wallet)
    const approveTx = await usdc.approve(escrowParams.contractAddress, BigInt(escrowParams.totalAmountWei))
    await approveTx.wait()

    const escrow = new ethers.Contract(escrowParams.contractAddress, ESCROW_ABI, wallet)
    const lockTx = await escrow.lockFunds(
      escrowParams.taskIdBytes32,
      escrowParams.sellerAddress,
      BigInt(escrowParams.totalAmountWei),
      escrowParams.timeoutSeconds,
      escrowParams.taskHashBytes32
    )
    const lockReceipt = await lockTx.wait()

    // 3. Report the lock tx hash — server verifies on-chain and marks ESCROWED
    await this.request(`/api/v1/transactions/${transactionId}/escrow-lock`, {
      method: 'POST',
      body: JSON.stringify({ escrowTxHash: lockReceipt.hash }),
    })

    // 4. Poll for RESULT_SUBMITTED
    const deadline = Date.now() + timeoutSeconds * 1000
    while (Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 2000))
      const tx = await this.request<Transaction>(`/api/v1/transactions/${transactionId}`)
      if (tx.status === 'RESULT_SUBMITTED') break
      if (['TIMED_OUT', 'REFUNDED', 'DISPUTED', 'COMPLETED'].includes(tx.status)) {
        throw new Error(`Transaction ended with status: ${tx.status}`)
      }
    }

    // 5. Sign the chain-bound release digest and confirm
    // Digest: keccak256(abi.encodePacked(taskIdBytes32, chainId, contractAddress))
    const domain = ethers.solidityPackedKeccak256(
      ['bytes32', 'uint256', 'address'],
      [
        escrowParams.taskIdBytes32,
        BigInt(escrowParams.chainId),
        escrowParams.contractAddress,
      ]
    )
    const signature = await wallet.signMessage(ethers.getBytes(domain))

    const { result } = await this.request<{ result: unknown }>(
      `/api/v1/transactions/${transactionId}/confirm`,
      {
        method: 'POST',
        body: JSON.stringify({ walletSignature: signature }),
      }
    )

    return { result, transactionId }
  }

  async getTransaction(id: string): Promise<Transaction> {
    return this.request<Transaction>(`/api/v1/transactions/${id}`)
  }

  async getReputation(agentId: string) {
    return this.request(`/api/v1/reputation/${agentId}`)
  }

  async getStats() {
    return this.request('/api/v1/stats')
  }
}
