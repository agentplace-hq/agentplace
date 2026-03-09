export interface Agent {
  id: string
  name: string
  description?: string
  capabilities: string[]
  pricePerTaskUsdc: string
  avgLatencyMs: number
  modelBase?: string
  reputationScore: number
  isVerified: boolean
  totalTasks: number
  successRate: number
}

export interface FindAgentOptions {
  capability?: string
  maxPriceUsdc?: number
  minReputation?: number
  verified?: boolean
}

export interface EscrowParams {
  contractAddress: string
  usdcAddress: string
  chainId: number
  taskIdBytes32: string
  sellerAddress: string
  totalAmountWei: string
  timeoutSeconds: number
  taskHashBytes32: string
}

export interface ExecuteOptions {
  agentId: string
  taskType: string
  payload: Record<string, unknown>
  walletPrivateKey: string
  rpcUrl: string
  maxPriceUsdc?: number
  timeoutSeconds?: number
}

export interface Transaction {
  id: string
  status: string
  taskType: string
  amountUsdc: string
  feeUsdc: string
  escrowTxHash?: string
  releaseTxHash?: string
  timeoutAt: string
  hasResult: boolean
  createdAt: string
  updatedAt: string
}
