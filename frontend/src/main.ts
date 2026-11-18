import {
  BaseError,
  createPublicClient,
  createWalletClient,
  custom,
  decodeErrorResult,
  defineChain,
  getAddress,
  type Abi,
  type Address,
  type Chain,
  type PublicClient,
  type WalletClient,
} from "viem";
import { bsc } from "viem/chains";
import { deskAbi, erc20Abi, mockRegistryAbi, mockUsdtAbi, registryAbi } from "./abi";
import { clearOverride, hasOverride, loadConfigs, saveOverride, type ChainConfig } from "./config";
import {
  defaultExpiryInput,
  escapeHtml,
  expiryToUnix,
  formatExact,
  formatGrouped,
  formatTime,
  parseUnits,
  percent,
  shortAddress,
} from "./format";

const localChain = defineChain({
  id: 31337,
  name: "Local / Fork",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
});

const MAX_UINT256 = (1n << 256n) - 1n;
const STATUSES = [
  { label: "进行中", cls: "live" },
  { label: "已暂停", cls: "warn" },
  { label: "已到期", cls: "stop" },
  { label: "已关闭", cls: "stop" },
  { label: "成交量已达标", cls: "stop" },
  { label: "已达亏损上限", cls: "stop" },
];

const ERROR_TEXT: Record<string, string> = {
  AgentIdRequired: "这个地址没有 Agent ID。",
  NotOwner: "只有策略所有者可以做这件事。",
  NotExecutor: "只有绑定的执行者可以支取或归还。",
  PolicyIsClosed: "策略已关闭。",
  PolicyIsPaused: "策略已暂停，现在不能支取。",
  PolicyExpired: "策略已到期，不能支取。",
  PolicyCompleted: "申报成交量已达到目标，不能再支取。",
  LossLimitReached: "累计亏损已达到上限，不能再支取。",
  OutstandingExists: "上一笔支取还没有结清。",
  NoOutstanding: "当前没有待归还的支取。",
  ExceedsMaxPerTrade: "超过单笔上限。",
  ExceedsEscrow: "超过当前托管余额。",
  ExceedsOutstanding: "归还金额超过未结清的支取。",
  ApprovalMustBeExact: "授权额度必须和这一笔金额完全相同。无限授权会被拒绝。",
  UnexpectedTransferAmount: "代币实际到账数量和填写金额不一致，交易已取消。",
  AmountZero: "金额必须大于 0。",
  ExpiryNotFuture: "到期时间必须晚于当前时间。",
  MaxPerTradeZero: "单笔上限必须大于 0。",
  VolumeTargetZero: "成交量目标必须大于 0。",
  MaxLossZero: "最大亏损必须大于 0。",
  DepositsClosed: "策略已经关闭、到期、达标或触及亏损上限，不能再存入。",
  AlreadyPaused: "策略已经处于暂停。",
  NotPaused: "策略没有暂停。",
  PolicyNotFound: "没有这个策略编号。",
  ZeroAddress: "地址不能是零地址。",
  NotAContract: "构造参数指向的地址上没有合约。",
  Reentrancy: "检测到重入，交易已取消。",
  TransferFailed: "代币转账失败。",
  Insolvency: "合约代币余额不足以覆盖记账中的托管，交易已取消。",
  NativeNotAccepted: "这个合约不接收原生币。",
};

type Policy = {
  id: bigint;
  owner: Address;
  executor: Address;
  ownerHandle: string;
  executorHandle: string;
  maxPerTrade: bigint;
  volumeTarget: bigint;
  maxLoss: bigint;
  expiry: bigint;
  escrow: bigint;
  outstanding: bigint;
  realizedLoss: bigint;
  recordedVolume: bigint;
  paused: boolean;
  closed: boolean;
  status: number;
};

type ModalState = {
  title: string;
  body: string;
  confirm: string;
  danger: boolean;
  run: () => Promise<void>;
};

const drafts = {
  executor: "",
  maxPerTrade: "25",
  volumeTarget: "1000",
  maxLoss: "50",
  expiry: defaultExpiryInput(),
  lookup: "",
  localHandle: "880",
  registry: "",
  usdt: "",
  desk: "",
  deposit: {} as Record<string, string>,
  pull: {} as Record<string, string>,
  repay: {} as Record<string, string>,
  volume: {} as Record<string, string>,
};

let configs: Record<string, ChainConfig> = {};
let account: Address | undefined;
let chainId: number | undefined;
let chainConfig: ChainConfig | undefined;
let policies: Policy[] = [];
let extraIds = new Set<string>();
let allowance = 0n;
let tokenBalance = 0n;
let decimals = 18;
let symbol = "USDT";
let hasAgent = false;
let handle = "";
let onchainRegistry = "";
let onchainUsdt = "";
let deskCode = false;
let errorText = "";
let noticeText = "";
let busy = false;
let loading = false;
let walletBound = false;
let draftedChain: number | null = null;
let modal: ModalState | null = null;
let publicClient: PublicClient | null = null;
let walletClient: WalletClient | null = null;

const walletRoot = document.querySelector<HTMLElement>("#wallet");
const mainRoot = document.querySelector<HTMLElement>("#main");
const modalRoot = document.querySelector<HTMLElement>("#modal-root");

function chainFor(id: number): Chain | null {
  if (id === bsc.id) return bsc;
  if (id === localChain.id) return localChain;
  return null;
}

function same(left: string, right: string): boolean {
  return left.toLowerCase() === right.toLowerCase();
}

function explain(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  if (/user rejected|user denied|denied transaction signature|4001/i.test(message)) {
    return "你在钱包里取消了这笔操作。";
  }
  if (/insufficient funds/i.test(message)) return "原生币不够支付 gas。";
  if (error instanceof BaseError) {
    const match = error.walk((node) => {
      const named = node as { name?: string; data?: { errorName?: string } };
      return named.name === "ContractFunctionRevertedError" && Boolean(named.data?.errorName);
    }) as { data?: { errorName?: string } } | null;
    const name = match?.data?.errorName;
    if (name && ERROR_TEXT[name]) return ERROR_TEXT[name];
    if (name) return `合约拒绝了这笔操作（${name}）。`;
  }
  const data = message.match(/0x[0-9a-fA-F]{8,}/)?.[0];
  if (data) {
    try {
      const decoded = decodeErrorResult({ abi: deskAbi, data: data as `0x${string}` });
      if (ERROR_TEXT[decoded.errorName]) return ERROR_TEXT[decoded.errorName];
      return `合约拒绝了这笔操作（${decoded.errorName}）。`;
    } catch {
      // The hex blob was not one of this contract's errors.
    }
  }
  for (const [name, text] of Object.entries(ERROR_TEXT)) {
    if (message.includes(name)) return text;
  }
  const short = message.replace(/\s+/g, " ").slice(0, 220);
  return short ? `没有完成：${short}` : "没有完成。";
}

function clients() {
  const ethereum = window.ethereum;
  if (!ethereum) return;
  const transport = custom(ethereum);
  publicClient = createPublicClient({ transport });
  walletClient = createWalletClient({ transport });
}

async function read<T>(address: Address, abi: Abi, functionName: string, args: readonly unknown[] = []): Promise<T> {
  if (!publicClient) throw new Error("钱包还没有连接。");
  return publicClient.readContract({ address, abi, functionName, args } as never) as Promise<T>;
}

async function write(abi: Abi, address: Address, functionName: string, args: readonly unknown[]): Promise<void> {
  if (!walletClient || !publicClient || !account || chainId == null) throw new Error("请先连接钱包。");
  const chain = chainFor(chainId);
  if (!chain) throw new Error("请切换到链 56，或本地链 31337。");
  const hash = await walletClient.writeContract({
    address,
    abi,
    functionName,
    args,
    account,
    chain,
  } as never);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error("交易失败。");
}

function money(value: bigint, precise = false): string {
  const text = precise ? formatExact(value, decimals) : formatGrouped(value, decimals);
  return `${escapeHtml(text)} ${escapeHtml(symbol)}`;
}

function addressHtml(address: string): string {
  const full = escapeHtml(address);
  const shown = escapeHtml(shortAddress(address));
  const base = chainConfig?.explorer?.replace(/\/$/, "");
  const label = base
    ? `<a href="${escapeHtml(base)}/address/${full}" target="_blank" rel="noreferrer">${shown}</a>`
    : shown;
  return `<span class="inline"><code class="addr" title="${full}">${label}</code><button type="button" class="ghost" data-action="copy" data-value="${full}">复制</button></span>`;
}

function partyHtml(title: string, partyHandle: string, address: string): string {
  const name = partyHandle ? escapeHtml(partyHandle) : "无 handle";
  return `<p><span class="muted">${title}</span> <strong>${name}</strong> ${addressHtml(address)}</p>`;
}

function disabled(reason: string | null): string {
  if (busy) return "disabled";
  return reason ? "disabled" : "";
}

function pullBlock(policy: Policy, isExecutor: boolean): string | null {
  if (!isExecutor) return "只有执行者可以支取。";
  if (policy.closed) return "策略已关闭。";
  if (policy.paused) return "策略已暂停。";
  if (policy.expiry <= BigInt(Math.floor(Date.now() / 1000))) return "策略已到期。";
  if (policy.recordedVolume >= policy.volumeTarget) return "申报成交量已达标。";
  if (policy.realizedLoss >= policy.maxLoss) return "已达到亏损上限。";
  if (policy.outstanding !== 0n) return "上一笔还没有结清。";
  if (policy.escrow === 0n) return "托管里没有余额。";
  return null;
}

function depositBlock(policy: Policy, isOwner: boolean): string | null {
  if (!isOwner) return "只有所有者可以存入。";
  if (policy.closed) return "策略已关闭。";
  if (policy.expiry <= BigInt(Math.floor(Date.now() / 1000))) return "策略已到期，不能再存入。";
  if (policy.recordedVolume >= policy.volumeTarget) return "成交量已达标，不能再存入。";
  if (policy.realizedLoss >= policy.maxLoss) return "已达亏损上限，不能再存入。";
  return null;
}

function policyCard(policy: Policy): string {
  const isOwner = Boolean(account && same(account, policy.owner));
  const isExecutor = Boolean(account && same(account, policy.executor));
  const status = STATUSES[policy.status] ?? { label: "未知", cls: "stop" };
  const id = policy.id.toString();
  const pullReason = pullBlock(policy, isExecutor);
  const depositReason = depositBlock(policy, isOwner);
  const volumeWidth = percent(policy.recordedVolume, policy.volumeTarget);
  const lossWidth = percent(policy.realizedLoss, policy.maxLoss);
  const role = !account
    ? "连接钱包后才能操作。"
    : isOwner && isExecutor
      ? "你同时是所有者和执行者。"
      : isOwner
        ? "你是所有者。"
        : isExecutor
          ? "你是执行者。"
          : "你不是这张策略的所有者或执行者，这里只显示状态。";

  return `<article class="policy">
    <header>
      <div>
        <p class="eyebrow">策略 #${escapeHtml(id)}</p>
        ${partyHtml("所有者", policy.ownerHandle, policy.owner)}
        ${partyHtml("执行者", policy.executorHandle, policy.executor)}
        <p class="hint">${role} 这里只显示这张策略双方的 Agent ID，不能按名字查询别人的钱包。</p>
      </div>
      <span class="stamp ${status.cls}">${status.label}</span>
    </header>
    ${
      policy.outstanding > 0n
        ? `<p class="outstanding">未归还 ${money(policy.outstanding, true)} 在执行者地址里。关闭策略不会追回这笔钱。</p>`
        : ""
    }
    <dl class="stats">
      <div><dt>托管</dt><dd>${money(policy.escrow, true)}</dd></div>
      <div><dt>未归还</dt><dd>${money(policy.outstanding, true)}</dd></div>
      <div><dt>已实现亏损 / 上限</dt><dd>${money(policy.realizedLoss)} / ${money(policy.maxLoss)}</dd></div>
      <div><dt>已申报成交量 / 目标</dt><dd>${money(policy.recordedVolume)} / ${money(policy.volumeTarget)}</dd></div>
      <div><dt>单笔上限</dt><dd>${money(policy.maxPerTrade)}</dd></div>
      <div><dt>到期</dt><dd>${escapeHtml(formatTime(policy.expiry))}</dd></div>
    </dl>
    <div class="meter loss" title="亏损相对上限"><span style="width:${lossWidth}%"></span></div>
    <div class="meter" title="申报成交量相对目标"><span style="width:${volumeWidth}%"></span></div>
    <p class="hint">成交量是执行者归还时填的数，合约不核验外部订单。亏损条只表示限额用了多少，不是收益。</p>
    ${
      isOwner
        ? `<div class="field-grid">
            <label>存入金额
              <input data-draft="deposit" data-id="${id}" inputmode="decimal" autocomplete="off" value="${escapeHtml(drafts.deposit[id] ?? "")}" placeholder="例如 100" />
            </label>
            <p class="hint">授权必须与这一笔金额完全相同。${depositReason ?? "暂停时仍可以存入。"}</p>
            <div class="actions">
              <button type="button" class="secondary" data-action="approve-deposit" data-id="${id}" ${disabled(depositReason)}>授权精确金额</button>
              <button type="button" class="primary" data-action="deposit" data-id="${id}" ${disabled(depositReason)}>存入托管</button>
              ${
                policy.paused
                  ? `<button type="button" class="secondary" data-action="unpause" data-id="${id}" ${disabled(policy.closed ? "已关闭" : null)}>恢复支取</button>`
                  : `<button type="button" class="secondary" data-action="pause" data-id="${id}" ${disabled(policy.closed ? "已关闭" : null)}>暂停支取</button>`
              }
              <button type="button" class="danger" data-action="close" data-id="${id}" ${disabled(policy.closed ? "已关闭" : null)}>关闭并退回剩余</button>
            </div>
          </div>`
        : ""
    }
    ${
      isExecutor
        ? `<div class="field-grid">
            <label>支取金额
              <input data-draft="pull" data-id="${id}" inputmode="decimal" autocomplete="off" value="${escapeHtml(drafts.pull[id] ?? "")}" placeholder="不超过单笔上限" />
            </label>
            <div class="actions">
              <button type="button" class="primary" data-action="pull" data-id="${id}" title="${escapeHtml(pullReason ?? "从托管支取到执行者地址")}" ${disabled(pullReason)}>支取</button>
            </div>
            ${pullReason ? `<p class="hint">${escapeHtml(pullReason)}</p>` : ""}
            <label>归还金额（留空表示全额归还）
              <input data-draft="repay" data-id="${id}" inputmode="decimal" autocomplete="off" value="${escapeHtml(drafts.repay[id] ?? "")}" placeholder="${escapeHtml(formatExact(policy.outstanding, decimals))}" />
            </label>
            <label>本次申报成交量
              <input data-draft="volume" data-id="${id}" inputmode="decimal" autocomplete="off" value="${escapeHtml(drafts.volume[id] ?? "")}" placeholder="0" />
            </label>
            <p class="hint">一次归还会结清整笔未还金额。少还的部分马上记为亏损，不能以后再补。</p>
            <div class="actions">
              <button type="button" class="secondary" data-action="approve-repay" data-id="${id}" ${disabled(policy.outstanding === 0n ? "没有未归还的支取。" : null)}>授权精确归还额</button>
              <button type="button" class="primary" data-action="repay" data-id="${id}" ${disabled(policy.outstanding === 0n ? "没有未归还的支取。" : null)}>归还并记录成交量</button>
            </div>
          </div>`
        : ""
    }
  </article>`;
}

function banners(): string {
  const blocks = [];
  if (errorText) blocks.push(`<div class="banner error" role="alert">${escapeHtml(errorText)}</div>`);
  if (noticeText) blocks.push(`<div class="banner ok" role="status">${escapeHtml(noticeText)}</div>`);
  if (loading) blocks.push(`<div class="banner" role="status">正在读取链上数据…</div>`);
  return blocks.join("");
}

function allowanceLine(): string {
  if (!chainConfig?.policyDesk || !account) return "";
  if (allowance === MAX_UINT256) {
    return `<p class="outstanding">当前对策略合约是无限授权。本合约会拒绝使用它。请先清零，再授权与本次金额相同的额度。</p>`;
  }
  return `<p class="hint">当前对策略合约的授权：${money(allowance, true)}。授权用完后应为 0。</p>`;
}

function renderWallet(): void {
  if (!walletRoot) return;
  if (!window.ethereum) {
    walletRoot.innerHTML = `<div class="wallet-card"><p>没有检测到注入钱包。</p><p class="hint">请在支持 window.ethereum 的浏览器中打开。本页不显示二维码，也不使用配对码。</p></div>`;
    return;
  }
  const chainLabel = chainId == null ? "未连接" : (chainConfig?.label ?? `链 ${chainId}`);
  const known = chainId != null && chainFor(chainId) != null;
  walletRoot.innerHTML = `<div class="wallet-card">
    ${
      account
        ? `<p class="handle">${handle ? escapeHtml(handle) : "无 Agent ID"}</p>
           <p>${addressHtml(account)}</p>
           <p class="hint">${hasAgent ? "这个地址持有 Agent ID，可以创建策略或被绑定为执行者。" : "这个地址目前没有 Agent ID，不能新建策略。"}</p>
           <p>代币余额 ${money(tokenBalance, true)}</p>`
        : `<p>尚未连接。连接只发生在你的钱包里，本页不保存会话。</p>`
    }
    <p>网络：${escapeHtml(chainLabel)}${known ? "" : chainId == null ? "" : "（本页只发送链 56 和本地 31337 的交易）"}</p>
    <div class="actions">
      <button type="button" class="primary" data-action="connect" ${busy ? "disabled" : ""}>${account ? "重新连接" : "连接钱包"}</button>
      <button type="button" class="secondary" data-action="switch" data-chain="56" ${busy ? "disabled" : ""}>切换到链 56</button>
      <button type="button" class="secondary" data-action="switch" data-chain="31337" ${busy ? "disabled" : ""}>切换到本地链</button>
      ${account ? `<button type="button" class="ghost" data-action="refresh" ${busy ? "disabled" : ""}>刷新</button>` : ""}
    </div>
  </div>`;
}

function renderMain(): void {
  if (!mainRoot) return;
  const desk = chainConfig?.policyDesk ?? "";
  const mismatch =
    desk &&
    deskCode &&
    ((onchainRegistry && chainConfig?.agentRegistry && !same(onchainRegistry, chainConfig.agentRegistry)) ||
      (onchainUsdt && chainConfig?.usdt && !same(onchainUsdt, chainConfig.usdt)));
  const policyHtml = policies.length
    ? policies.map(policyCard).join("")
    : `<div class="card empty"><h2>还没有相关策略</h2><p>列表只包含你作为所有者或执行者的策略，加上你按编号打开的策略。持有 Agent ID 的地址可以创建新策略。任何其他持有者也可以使用同一份合约。</p></div>`;

  mainRoot.innerHTML = `${banners()}
    <section class="steps">
      <article><strong>1. 确认身份</strong><p class="hint">连接后只读取你自己的 Agent ID。balanceOf 大于 0 才能创建或被绑定。</p></article>
      <article><strong>2. 写下限额</strong><p class="hint">单笔上限、亏损上限、成交量目标和到期时间写进合约后不能修改。</p></article>
      <article><strong>3. 精确托管</strong><p class="hint">先授权与存入额相同的代币，再存入。执行者只能在规则内支取一笔，归还后才能再取。</p></article>
    </section>
    <div class="layout">
      <section class="stack">
        <form class="card create" data-form="create">
          <h2>创建策略</h2>
          <div class="field-grid">
            <label>执行者地址
              <input data-draft="executor" spellcheck="false" autocomplete="off" value="${escapeHtml(drafts.executor)}" placeholder="0x… 可以是你自己" />
              <button type="button" class="ghost" data-action="fill-self">填入当前地址</button>
              <span class="hint">执行者也必须持有 Agent ID。所有者和执行者可以是同一个地址。</span>
            </label>
            <label>单笔上限
              <input data-draft="maxPerTrade" inputmode="decimal" value="${escapeHtml(drafts.maxPerTrade)}" />
              <span class="hint">每一笔支取不能超过它。同一时间只能有一笔未结清支取。</span>
            </label>
            <label>成交量目标
              <input data-draft="volumeTarget" inputmode="decimal" value="${escapeHtml(drafts.volumeTarget)}" />
              <span class="hint">执行者自己申报。达到目标后停止支取，合约不检查外部成交。</span>
            </label>
            <label>最大亏损
              <input data-draft="maxLoss" inputmode="decimal" value="${escapeHtml(drafts.maxLoss)}" />
              <span class="hint">少还的累计金额达到这里之后，不能再支取。这是执行者可以不归还的上限。</span>
            </label>
            <label>到期时间
              <input data-draft="expiry" type="datetime-local" value="${escapeHtml(drafts.expiry)}" />
            </label>
            <p id="create-preview" class="hint"></p>
            <button type="submit" class="primary" ${busy ? "disabled" : ""}>创建策略</button>
          </div>
        </form>
        <form class="card" data-form="lookup">
          <h2>按编号查看</h2>
          <label>策略编号
            <input data-draft="lookup" inputmode="numeric" value="${escapeHtml(drafts.lookup)}" placeholder="1" />
          </label>
          <p class="hint">只能按编号打开一张已知策略。不能用 handle 反查钱包。</p>
          <button type="submit" class="secondary" ${busy ? "disabled" : ""}>查看</button>
        </form>
        ${renderConfig()}
        ${renderLocalTools()}
      </section>
      <section class="stack">
        ${
          account && !desk
            ? `<div class="card"><h2>还没有填策略合约地址</h2><p>这份代码不会替你部署到主网。部署之后，把地址填进本页配置或 <code>frontend/public/config.json</code>。链 56 的 Agent ID 注册表和 USDT 地址已经填好。</p></div>`
            : ""
        }
        ${
          mismatch
            ? `<div class="banner error">页面里的注册表或代币地址，和策略合约构造时写入的地址不一致。合约实际使用 ${escapeHtml(onchainRegistry)} 和 ${escapeHtml(onchainUsdt)}。</div>`
            : ""
        }
        ${allowanceLine()}
        ${desk && !deskCode && account ? `<div class="banner error">当前网络上这个策略合约地址没有代码。请确认部署网络和地址。</div>` : ""}
        ${policyHtml}
        ${knownChainsHtml()}
      </section>
    </div>`;
  updatePreview();
}

function knownChainsHtml(): string {
  const rows = Object.entries(configs)
    .map(([id, cfg]) => {
      return `<li><strong>${escapeHtml(cfg.label)}</strong>（链 ${escapeHtml(id)}）<br />注册表 <code class="addr">${escapeHtml(cfg.agentRegistry || "未填")}</code><br />代币 <code class="addr">${escapeHtml(cfg.usdt || "未填")}</code><br />策略合约 <code class="addr">${escapeHtml(cfg.policyDesk || "部署后填写")}</code></li>`;
    })
    .join("");
  if (!rows) return "";
  return `<div class="card"><h2>配置里的合约</h2><ul>${rows}</ul><p class="hint">链 56 的策略合约故意留空：这个仓库不会替你部署。本地链地址对应全新节点上默认账户发出的前三笔创建交易；如果你的部署日志不同，用日志里的地址覆盖。</p></div>`;
}

function renderConfig(): string {
  return `<details class="card config" ${chainConfig?.policyDesk ? "" : "open"}>
    <summary>网络与合约地址${chainId != null && hasOverride(chainId) ? "（本机已覆盖）" : ""}</summary>
    <div class="field-grid">
      <p class="hint">这些地址只保存在这台浏览器里，用来指向已经部署的合约。这里不保存钱包或密钥。</p>
      <label>Agent ID 注册表
        <input data-draft="registry" spellcheck="false" autocomplete="off" value="${escapeHtml(drafts.registry)}" />
      </label>
      <label>托管代币
        <input data-draft="usdt" spellcheck="false" autocomplete="off" value="${escapeHtml(drafts.usdt)}" />
      </label>
      <label>策略合约
        <input data-draft="desk" spellcheck="false" autocomplete="off" value="${escapeHtml(drafts.desk)}" />
      </label>
      <div class="actions">
        <button type="button" class="primary" data-action="save-config" ${busy || chainId == null ? "disabled" : ""}>保存到本机</button>
        <button type="button" class="ghost" data-action="clear-config" ${busy || chainId == null ? "disabled" : ""}>清除本机覆盖</button>
      </div>
    </div>
  </details>`;
}

function renderLocalTools(): string {
  if (chainId !== 31337) return "";
  return `<form class="card" data-form="local">
    <h2>本地测试</h2>
    <p class="hint">只在链 31337 的测试注册表上给当前地址登记 handle，并领取测试代币。主网注册表没有这些功能。测试币没有价值。</p>
    <label>演示 handle
      <input data-draft="localHandle" value="${escapeHtml(drafts.localHandle)}" spellcheck="false" autocomplete="off" />
      <span class="hint">小写字母和数字，不要加后缀。</span>
    </label>
    <div class="actions">
      <button type="button" class="secondary" data-action="set-agent" ${busy ? "disabled" : ""}>登记演示 Agent ID</button>
      <button type="button" class="secondary" data-action="mint" ${busy ? "disabled" : ""}>领取 10,000 测试币</button>
    </div>
  </form>`;
}

function renderModal(): void {
  if (!modalRoot) return;
  if (!modal) {
    modalRoot.innerHTML = "";
    return;
  }
  modalRoot.innerHTML = `<div class="modal-back" data-action="close-modal">
    <div class="modal" role="dialog" aria-modal="true" aria-labelledby="modal-title">
      <h2 id="modal-title">${escapeHtml(modal.title)}</h2>
      <p>${escapeHtml(modal.body)}</p>
      <div class="actions">
        <button type="button" class="${modal.danger ? "danger" : "primary"}" data-action="confirm-modal" ${busy ? "disabled" : ""}>${escapeHtml(modal.confirm)}</button>
        <button type="button" class="ghost" data-action="close-modal">返回</button>
      </div>
    </div>
  </div>`;
}

function render(): void {
  syncConfigDrafts();
  renderWallet();
  renderMain();
  renderModal();
}

function syncConfigDrafts(): void {
  if (!chainConfig || chainId == null) return;
  if (draftedChain === chainId) return;
  drafts.registry = chainConfig.agentRegistry;
  drafts.usdt = chainConfig.usdt;
  drafts.desk = chainConfig.policyDesk;
  draftedChain = chainId;
}

function updatePreview(): void {
  const node = document.getElementById("create-preview");
  if (!node) return;
  const executor = drafts.executor.trim() || "（未填执行者）";
  node.textContent = `将创建：执行者 ${executor}，单笔不超过 ${drafts.maxPerTrade || "0"} ${symbol}，申报成交量达到 ${drafts.volumeTarget || "0"} 后停止支取，累计亏损达到 ${drafts.maxLoss || "0"} 后停止支取，到期 ${drafts.expiry || "未填"}。`;
}

function rememberDraft(target: HTMLInputElement): void {
  const key = target.dataset.draft;
  if (!key) return;
  const id = target.dataset.id;
  if (id && (key === "deposit" || key === "pull" || key === "repay" || key === "volume")) {
    drafts[key][id] = target.value;
    return;
  }
  if (
    key === "executor" ||
    key === "maxPerTrade" ||
    key === "volumeTarget" ||
    key === "maxLoss" ||
    key === "expiry" ||
    key === "lookup" ||
    key === "localHandle" ||
    key === "registry" ||
    key === "usdt" ||
    key === "desk"
  ) {
    drafts[key] = target.value;
  }
  if (key === "executor" || key === "maxPerTrade" || key === "volumeTarget" || key === "maxLoss" || key === "expiry") {
    updatePreview();
  }
}

function policyById(id: string): Policy | undefined {
  return policies.find((policy) => policy.id.toString() === id);
}

function parseAddress(value: string, label: string): Address {
  try {
    return getAddress(value.trim());
  } catch {
    throw new Error(`${label}不是有效地址。`);
  }
}

function amountFrom(raw: string): bigint {
  const amount = parseUnits(raw, decimals);
  if (amount <= 0n) throw new Error("金额必须大于 0。");
  return amount;
}

async function run(
  label: string,
  job: () => Promise<void>,
  success = "钱包已确认，链上状态已刷新。",
): Promise<void> {
  if (busy) return;
  busy = true;
  errorText = "";
  noticeText = label;
  render();
  try {
    await job();
    noticeText = success;
    await refresh();
  } catch (error) {
    errorText = explain(error);
    noticeText = "";
  } finally {
    busy = false;
    render();
  }
}

function openModal(next: ModalState): void {
  modal = next;
  render();
}

async function connect(): Promise<void> {
  const ethereum = window.ethereum;
  if (!ethereum) throw new Error("没有检测到注入钱包。");
  const accounts = (await ethereum.request({ method: "eth_requestAccounts" })) as string[];
  account = accounts[0] ? getAddress(accounts[0]) : undefined;
  clients();
  await refresh();
}

async function switchChain(id: number): Promise<void> {
  const ethereum = window.ethereum;
  if (!ethereum) throw new Error("没有检测到注入钱包。");
  const hex = `0x${id.toString(16)}`;
  try {
    await ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hex }] });
  } catch (error) {
    const code = (error as { code?: number }).code;
    if (code !== 4902) throw error;
    const params =
      id === 56
        ? {
            chainId: hex,
            chainName: "BNB Smart Chain",
            nativeCurrency: { name: "BNB", symbol: "BNB", decimals: 18 },
            rpcUrls: ["https://bsc-dataseed.bnbchain.org"],
            blockExplorerUrls: ["https://bscscan.com"],
          }
        : {
            chainId: hex,
            chainName: "Local Fork",
            nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
            rpcUrls: ["http://127.0.0.1:8545"],
          };
    await ethereum.request({ method: "wallet_addEthereumChain", params: [params] });
  }
}

async function refresh(): Promise<void> {
  loading = true;
  render();
  try {
    configs = await loadConfigs();
    const ethereum = window.ethereum;
    if (ethereum) {
      clients();
      const hex = (await ethereum.request({ method: "eth_chainId" })) as string;
      chainId = Number(hex);
      if (!account) {
        const existing = (await ethereum.request({ method: "eth_accounts" })) as string[];
        account = existing[0] ? getAddress(existing[0]) : undefined;
      }
    }
    chainConfig = chainId == null ? undefined : configs[String(chainId)];
    policies = [];
    hasAgent = false;
    handle = "";
    allowance = 0n;
    tokenBalance = 0n;
    onchainRegistry = "";
    onchainUsdt = "";
    deskCode = false;
    if (!publicClient || !account || !chainConfig) return;

    if (chainConfig.agentRegistry) {
      const balance = await read<bigint>(chainConfig.agentRegistry, registryAbi, "balanceOf", [account]);
      hasAgent = balance > 0n;
      if (hasAgent) {
        try {
          handle = await read<string>(chainConfig.agentRegistry, registryAbi, "handleOf", [account]);
        } catch {
          handle = "";
        }
      }
    }
    if (chainConfig.usdt) {
      try {
        decimals = Number(await read<number>(chainConfig.usdt, erc20Abi, "decimals"));
        symbol = (await read<string>(chainConfig.usdt, erc20Abi, "symbol")) || "USDT";
      } catch {
        decimals = 18;
        symbol = "USDT";
      }
      tokenBalance = await read<bigint>(chainConfig.usdt, erc20Abi, "balanceOf", [account]);
    }
    const desk = chainConfig.policyDesk;
    if (!desk) return;
    const code = await publicClient.getBytecode({ address: desk });
    deskCode = Boolean(code && code !== "0x");
    if (!deskCode) return;
    onchainRegistry = await read<Address>(desk, deskAbi, "agentRegistry");
    onchainUsdt = await read<Address>(desk, deskAbi, "usdt");
    if (chainConfig.usdt) {
      allowance = await read<bigint>(chainConfig.usdt, erc20Abi, "allowance", [account, desk]);
    }
    const ownerIds = await read<bigint[]>(desk, deskAbi, "ownerPolicyIds", [account]);
    const executorIds = await read<bigint[]>(desk, deskAbi, "executorPolicyIds", [account]);
    const ids = new Set<string>([...ownerIds, ...executorIds, ...extraIds].map((id) => id.toString()));
    const ordered = [...ids].sort((left, right) => Number(BigInt(right) - BigInt(left)));
    const loaded: Policy[] = [];
    for (const id of ordered) {
      const row = await read<unknown>(desk, deskAbi, "getPolicy", [BigInt(id)]);
      loaded.push(normalizePolicy(row));
    }
    policies = loaded;
  } finally {
    loading = false;
  }
}

function normalizePolicy(value: unknown): Policy {
  const row = value as {
    id: bigint;
    ownerHandle: string;
    executorHandle: string;
    status: number | bigint;
    policy: {
      owner: Address;
      executor: Address;
      maxPerTrade: bigint;
      volumeTarget: bigint;
      maxLoss: bigint;
      expiry: bigint;
      paused: boolean;
      closed: boolean;
      escrow: bigint;
      outstanding: bigint;
      realizedLoss: bigint;
      recordedVolume: bigint;
    };
  };
  return {
    id: BigInt(row.id),
    owner: row.policy.owner,
    executor: row.policy.executor,
    ownerHandle: row.ownerHandle ?? "",
    executorHandle: row.executorHandle ?? "",
    maxPerTrade: BigInt(row.policy.maxPerTrade),
    volumeTarget: BigInt(row.policy.volumeTarget),
    maxLoss: BigInt(row.policy.maxLoss),
    expiry: BigInt(row.policy.expiry),
    paused: Boolean(row.policy.paused),
    closed: Boolean(row.policy.closed),
    escrow: BigInt(row.policy.escrow),
    outstanding: BigInt(row.policy.outstanding),
    realizedLoss: BigInt(row.policy.realizedLoss),
    recordedVolume: BigInt(row.policy.recordedVolume),
    status: Number(row.status),
  };
}

function requireDesk(): Address {
  if (!chainConfig?.policyDesk) throw new Error("先填好策略合约地址。");
  if (!deskCode) throw new Error("策略合约地址上没有代码。");
  return chainConfig.policyDesk;
}

function requireUsdt(): Address {
  if (!chainConfig?.usdt) throw new Error("先填好代币地址。");
  return chainConfig.usdt;
}

async function onCreate(): Promise<void> {
  if (!account) throw new Error("请先连接钱包。");
  if (!hasAgent) throw new Error("当前地址没有 Agent ID，不能创建策略。");
  const desk = requireDesk();
  const executor = parseAddress(drafts.executor, "执行者");
  await write(deskAbi, desk, "createPolicy", [
    executor,
    amountFrom(drafts.maxPerTrade),
    amountFrom(drafts.volumeTarget),
    amountFrom(drafts.maxLoss),
    expiryToUnix(drafts.expiry),
  ]);
}

async function onDeposit(id: string, approveOnly: boolean): Promise<void> {
  const policy = policyById(id);
  if (!policy) throw new Error("找不到这张策略。");
  const amount = amountFrom(drafts.deposit[id] ?? "");
  if (approveOnly) {
    await write(erc20Abi, requireUsdt(), "approve", [requireDesk(), amount]);
    return;
  }
  await write(deskAbi, requireDesk(), "deposit", [policy.id, amount]);
}

async function onRepay(id: string, approveOnly: boolean): Promise<void> {
  const policy = policyById(id);
  if (!policy) throw new Error("找不到这张策略。");
  if (policy.outstanding === 0n) throw new Error("当前没有待归还的支取。");
  const typed = (drafts.repay[id] ?? "").trim();
  const amount = typed ? parseUnits(typed, decimals) : policy.outstanding;
  if (amount > policy.outstanding) throw new Error("归还金额不能超过未结清的支取。");
  const volume = (drafts.volume[id] ?? "").trim() ? parseUnits(drafts.volume[id] ?? "0", decimals) : 0n;
  if (approveOnly) {
    if (amount === 0n) throw new Error("归还 0 不需要授权。直接提交即可把整笔记成亏损。");
    await write(erc20Abi, requireUsdt(), "approve", [requireDesk(), amount]);
    return;
  }
  const job = () => write(deskAbi, requireDesk(), "repay", [policy.id, amount, volume]);
  if (amount < policy.outstanding) {
    openModal({
      title: "少还会立刻记成亏损",
      body: `未结清 ${formatExact(policy.outstanding, decimals)} ${symbol}。这次归还 ${formatExact(amount, decimals)} ${symbol}，差额 ${formatExact(policy.outstanding - amount, decimals)} ${symbol} 记为亏损，以后不能再补同一笔。`,
      confirm: "确认结清",
      danger: true,
      run: job,
    });
    return;
  }
  await run("等待钱包确认归还…", job);
}

async function onPull(id: string): Promise<void> {
  const policy = policyById(id);
  if (!policy) throw new Error("找不到这张策略。");
  const amount = amountFrom(drafts.pull[id] ?? "");
  openModal({
    title: "支取会离开托管",
    body: `将取出 ${formatExact(amount, decimals)} ${symbol} 到执行者地址。归还之前，所有者不能通过合约收回。请确认金额没有超过单笔上限。`,
    confirm: "继续，去钱包确认",
    danger: true,
    run: () => write(deskAbi, requireDesk(), "pull", [policy.id, amount]),
  });
}

async function onClose(id: string): Promise<void> {
  const policy = policyById(id);
  if (!policy) throw new Error("找不到这张策略。");
  const stuck =
    policy.outstanding > 0n
      ? `已经支取且未归还的 ${formatExact(policy.outstanding, decimals)} ${symbol} 留在执行者地址，关闭不会追回。`
      : "当前没有未归还的支取。";
  openModal({
    title: "关闭并退回剩余托管",
    body: `仍在合约里的 ${formatExact(policy.escrow, decimals)} ${symbol} 会退回所有者。${stuck}`,
    confirm: "确认关闭",
    danger: true,
    run: () => write(deskAbi, requireDesk(), "close", [policy.id]),
  });
}

async function onAction(action: string, id: string): Promise<void> {
  if (action === "pause") {
    await write(deskAbi, requireDesk(), "pause", [BigInt(id)]);
    return;
  }
  if (action === "unpause") {
    await write(deskAbi, requireDesk(), "unpause", [BigInt(id)]);
    return;
  }
  if (action === "deposit") return onDeposit(id, false);
  if (action === "approve-deposit") return onDeposit(id, true);
  if (action === "pull") return onPull(id);
  if (action === "repay") return onRepay(id, false);
  if (action === "approve-repay") return onRepay(id, true);
  if (action === "close") return onClose(id);
}

function bind(): void {
  document.addEventListener("input", (event) => {
    const target = event.target;
    if (target instanceof HTMLInputElement) rememberDraft(target);
  });
  document.addEventListener("click", (event) => {
    const target = event.target;
    if (!(target instanceof HTMLElement)) return;
    const actor = target.closest<HTMLElement>("[data-action]");
    if (!actor) return;
    if (actor.classList.contains("modal-back") && target !== actor) return;
    const action = actor.dataset.action ?? "";
    const id = actor.dataset.id ?? "";
    void handleClick(action, id, actor);
  });
  document.addEventListener("submit", (event) => {
    const form = event.target;
    if (!(form instanceof HTMLFormElement)) return;
    event.preventDefault();
    const kind = form.dataset.form;
    if (kind === "create") void run("等待钱包确认创建…", onCreate);
    if (kind === "lookup") void run("正在查询策略…", lookup, "已打开这张策略。");
    if (kind === "local") event.preventDefault();
  });
  const ethereum = window.ethereum;
  if (ethereum?.on && !walletBound) {
    walletBound = true;
    ethereum.on("accountsChanged", (accounts) => {
      const list = accounts as string[];
      account = list[0] ? getAddress(list[0]) : undefined;
      void refresh().then(render).catch((reason) => {
        errorText = explain(reason);
        render();
      });
    });
    ethereum.on("chainChanged", () => {
      draftedChain = null;
      void refresh().then(render).catch((reason) => {
        errorText = explain(reason);
        render();
      });
    });
  }
}

async function lookup(): Promise<void> {
  const desk = requireDesk();
  let id: bigint;
  try {
    id = BigInt(drafts.lookup.trim());
  } catch {
    throw new Error("策略编号必须是正整数。");
  }
  if (id <= 0n) throw new Error("策略编号必须是正整数。");
  await read(desk, deskAbi, "getPolicy", [id]);
  extraIds.add(id.toString());
}

async function handleClick(action: string, id: string, actor: HTMLElement): Promise<void> {
  try {
    if (action === "close-modal") {
      modal = null;
      render();
      return;
    }
    if (action === "confirm-modal" && modal) {
      const job = modal.run;
      modal = null;
      await run("等待钱包确认…", job);
      return;
    }
    if (action === "copy") {
      const value = actor.dataset.value ?? "";
      await navigator.clipboard.writeText(value);
      noticeText = "已复制。";
      errorText = "";
      render();
      return;
    }
    if (action === "fill-self") {
      if (!account) throw new Error("请先连接钱包。");
      drafts.executor = account;
      render();
      return;
    }
    if (action === "connect") {
      await run("正在连接钱包…", connect, "钱包已连接。");
      return;
    }
    if (action === "refresh") {
      await run("正在刷新…", async () => undefined, "已刷新。");
      return;
    }
    if (action === "switch") {
      const next = Number(actor.dataset.chain);
      await run("等待钱包切换网络…", () => switchChain(next));
      return;
    }
    if (action === "save-config") {
      if (chainId == null) throw new Error("先连接钱包，以便知道要保存哪一条链。");
      saveOverride(chainId, {
        agentRegistry: getAddressOrBlank(drafts.registry),
        usdt: getAddressOrBlank(drafts.usdt),
        policyDesk: getAddressOrBlank(drafts.desk),
      });
      draftedChain = null;
      noticeText = "地址已保存在这台浏览器。";
      errorText = "";
      await refresh();
      render();
      return;
    }
    if (action === "clear-config") {
      if (chainId == null) return;
      clearOverride(chainId);
      draftedChain = null;
      noticeText = "已清除本机覆盖，恢复配置文件中的地址。";
      await refresh();
      render();
      return;
    }
    if (action === "set-agent") {
      if (chainId !== 31337) throw new Error("登记演示身份只在本地链可用。");
      if (!account) throw new Error("请先连接钱包。");
      const registry = chainConfig?.agentRegistry;
      if (!registry) throw new Error("先填好本地注册表地址。");
      const nextHandle = drafts.localHandle.trim();
      if (!/^[a-z0-9]{1,32}$/.test(nextHandle)) throw new Error("handle 只能是 1 到 32 位小写字母或数字。");
      await run("等待钱包确认登记…", () => write(mockRegistryAbi, registry, "setAgent", [account, nextHandle]));
      return;
    }
    if (action === "mint") {
      if (chainId !== 31337) throw new Error("领取测试币只在本地链可用。");
      if (!account) throw new Error("请先连接钱包。");
      const token = chainConfig?.usdt;
      if (!token) throw new Error("先填好本地代币地址。");
      await run("等待钱包确认领取…", () => write(mockUsdtAbi, token, "mint", [account, parseUnits("10000", decimals)]));
      return;
    }
    if (action === "pull" || action === "close" || action === "repay") {
      await onAction(action, id);
      return;
    }
    if (action) {
      await run("等待钱包确认…", () => onAction(action, id));
    }
  } catch (error) {
    errorText = explain(error);
    noticeText = "";
    render();
  }
}

function getAddressOrBlank(value: string): Address | "" {
  const trimmed = value.trim();
  if (!trimmed) return "";
  return parseAddress(trimmed, "合约");
}

bind();
void refresh()
  .then(render)
  .catch((reason) => {
    errorText = explain(reason);
    render();
  });
