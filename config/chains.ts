/**
 * Robinhood Chain configuration for Stockgift.
 *
 * Every address below was taken from an official source and verified on-chain on 2026-10-08
 * (symbol()/decimals() calls, Uniswap factory getPool(), Chainlink latestRoundData()).
 * Never add an address here without a source link.
 *
 * Sources
 * - Chain (ID 4663, RPC, explorer, ETH gas):     https://docs.robinhood.com/chain/
 * - Token contracts (USDG, WETH, stock tokens):   https://docs.robinhood.com/chain/contracts
 *   machine-readable list:                        https://api.robinhood.com/rhj/assets  (deployments[chainId=4663])
 * - Protocol contracts (Permit2, multicall):      https://docs.robinhood.com/chain/protocol-contracts
 * - Chainlink price feeds (stock/USD, USDG/USD):  https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
 *   machine-readable list:                        https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json
 * - Uniswap v3 deployment:                        https://developers.uniswap.org/docs/protocols/v3/deployments/v3-robinhood-chain-deployments
 * - Contract verification: Blockscout             https://robinhoodchain.blockscout.com/api/  (forge --verifier blockscout)
 *
 * Gaps (documented in DECISIONS.md / THREAT_MODEL.md):
 * - No Chainlink L2 sequencer-uptime feed is published for Robinhood Chain -> OracleAdapter keeps the
 *   check optional (address(0) = disabled) so it can be switched on via the Timelock when one exists.
 * - USDC is not listed in the official token contracts page; USDG is the canonical stablecoin used here.
 */

export type StockToken = {
  symbol: string;
  name: string;
  address: `0x${string}`;
  decimals: 18;
  /** Chainlink <SYMBOL>/USD proxy, 8 decimals, 24/5 equities feed (multiplier-adjusted) */
  feed: `0x${string}`;
  /** Uniswap v3 USDG pool fee tier used by the DexAdapter route */
  poolFee: 500 | 3000 | 10000;
  pool: `0x${string}`;
};

export const robinhoodChain = {
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["https://rpc.mainnet.chain.robinhood.com"] },
  },
  blockExplorers: {
    default: { name: "Blockscout", url: "https://robinhoodchain.blockscout.com", apiUrl: "https://robinhoodchain.blockscout.com/api" },
  },
  contracts: {
    multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" as `0x${string}` },
  },
} as const;

export const ROBINHOOD_MAINNET = {
  chainId: 4663,
  verification: { verifier: "blockscout", url: "https://robinhoodchain.blockscout.com/api/" },
  tokens: {
    USDG: { address: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168", decimals: 6, feed: "0x61B7e5650328764B076A108EFF5fa7282a1B9aD2" },
    WETH: { address: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73", decimals: 18, feed: "0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9" },
  },
  uniswapV3: {
    factory: "0x1f7d7550b1b028f7571e69a784071f0205fd2efa",
    swapRouter02: "0xcaf681a66d020601342297493863e78c959e5cb2",
    quoterV2: "0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7",
    universalRouter: "0x8876789976decbfcbbbe364623c63652db8c0904",
  },
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  sequencerUptimeFeed: null, // not published for this chain (see header)
  /** Launch curated list: tokens with a Chainlink feed AND a USDG Uniswap v3 pool with >$50k USDG depth at research time (AMD lowest at ~$87k). */
  stocks: [
    { symbol: "AAPL", name: "Apple", address: "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9", decimals: 18, feed: "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0", poolFee: 500, pool: "0xaae0d815ee56e4092a5e5c2911e676fea50b2d6d" },
    { symbol: "TSLA", name: "Tesla", address: "0x322F0929c4625eD5bAd873c95208D54E1c003b2d", decimals: 18, feed: "0x4A1166a659A55625345e9515b32adECea5547C38", poolFee: 3000, pool: "0xf4acdaeeb7022862a763c9b1b885e11191c889e3" },
    { symbol: "NVDA", name: "NVIDIA", address: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", decimals: 18, feed: "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15", poolFee: 500, pool: "0xd4eb21209c4d6093f80b5b84f5c45cc093ea14a3" },
    { symbol: "MSFT", name: "Microsoft", address: "0xe93237C50D904957Cf27E7B1133b510C669c2e74", decimals: 18, feed: "0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E", poolFee: 3000, pool: "0xeb60bcd1d920ad6e102690ccfc6fb488899e1510" },
    { symbol: "AMZN", name: "Amazon", address: "0x12f190a9F9d7D37a250758b26824B97CE941bF54", decimals: 18, feed: "0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C", poolFee: 3000, pool: "0x8ac92da74ab5f3b1d024dc1943ad7e15dc4179ef" },
    { symbol: "GOOGL", name: "Alphabet Class A", address: "0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3", decimals: 18, feed: "0xF6f373a037c30F0e5010d854385cA89185AE638b", poolFee: 500, pool: "0x34d0dc122cf9a8eb296fc5e0d3a233625d7d19b7" },
    { symbol: "META", name: "Meta Platforms", address: "0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35", decimals: 18, feed: "0x7C38C00C30BEe9378381E7B6135d7283356D71b1", poolFee: 3000, pool: "0x107a7cb40d8665360ba10e59471af06150a50922" },
    { symbol: "SPY", name: "SPDR S&P 500 ETF", address: "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C", decimals: 18, feed: "0x319724394D3A0e3669269846abE664Cd621f9f6A", poolFee: 500, pool: "0xa7bb1ac63bbab0c44316e6c8c455213441689167" },
    { symbol: "QQQ", name: "Invesco QQQ", address: "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68", decimals: 18, feed: "0x80901d846d5D7B030F26B480776EE3b29374C2ae", poolFee: 500, pool: "0xd60a5d14db690b7afad71f76b108071d7175597d" },
    { symbol: "AMD", name: "AMD", address: "0x86923f96303D656E4aa86D9d42D1e57ad2023fdC", decimals: 18, feed: "0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72", poolFee: 3000, pool: "0x48d284a2a4d3dc1b3da08231fe44317e7e7aa51f" },
    { symbol: "PLTR", name: "Palantir", address: "0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A", decimals: 18, feed: "0x820ABedFF239034956B7A9d2F0a331f9F075eB4c", poolFee: 3000, pool: "0x851680416a4f4e1c463d45171d61acddbc8554c0" },
    { symbol: "SPCX", name: "SpaceX Class A", address: "0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa", decimals: 18, feed: "0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb", poolFee: 500, pool: "0xc61284332117c3fb23a2a56cceffd07f7af60029" },
  ] as StockToken[],
} as const;

export type ChainConfig = typeof ROBINHOOD_MAINNET;
