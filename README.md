# AgentPolicyDesk

Agent 880 链上规则执行助手

持有 Agent ID 的人把交易限额写进合约，并可以把 USDT 放进该策略的托管。只有绑定的执行者能在这些限额里支取。合约不承诺收益，也不替任何人自动交易。

On-chain rules and token escrow for Agent ID wallets. An Agent ID holder writes the limits. Only the bound executor can pull, and only inside those limits. Nothing here promises a return.

合约名是 `AgentPolicyDesk`。它不包含交易所品牌，也没有建议域名。

## 这是什么

Agent 880（handle `880`）是第一个使用者，但合约并不写死这个 handle。任何一个 `balanceOf(address) > 0` 的地址都可以创建策略，也可以被绑定为执行者。所有者和执行者可以是同一个地址。

它解决的是「代理人在替我动用资金，但权限说不清、事后也难核对」。规则在链上：单笔上限、累计亏损上限、申报成交量目标和到期时间。页面只是钱包的操作台，没有后端，也没有服务器签名者。

## Agent ID 怎么用

身份和准入只用官方登记表上的两个读取：

| 调用 | 作用 |
| --- | --- |
| `balanceOf(address) > 0` | 创建策略时的准入。调用者和执行者都必须持有 Agent ID。 |
| `handleOf(address)` | 只用于显示 handle，不加 `.ai` 后缀。 |

链上登记表（BNB Smart Chain，chain id 56）：`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`

准入只在 `createPolicy` 时检查。之后的暂停、关闭、支取和归还认的是策略里记下的地址。这样即使登记表暂时读不出来，所有者也能关闭并取回剩余托管，执行者也能把钱还回来。在这条链上 Agent ID 是灵魂绑定的，创建时通过检查的地址会一直持有它。

这个产品不是名录。合约和页面都不会按 handle 反查别人的钱包。页面只显示当前连接的钱包自己的 handle，以及你正在看的那张策略的双方。

## 合约在做什么

金额都是代币的最小单位。目标代币是 USDT `0x55d398326f99059fF775485246999027B3197955`，18 位小数。

1. `createPolicy(executor, maxPerTrade, volumeTarget, maxLoss, expiry)`  
   三个限额都必须大于 0，到期时间必须晚于当前区块时间。
2. `deposit(policyId, amount)`  
   只有所有者。代币对合约的授权必须**正好等于**这次金额。`type(uint256).max` 一律拒绝。暂停时仍可存入；关闭、到期、成交量达标或亏损达标之后不能再存。
3. `pull(policyId, amount)`  
   只有执行者。策略不能处于暂停、关闭、到期、成交量达标或亏损达标，不能已有未结清支取，金额不能超过单笔上限和当前托管。代币立刻转到执行者地址。
4. `repay(policyId, repayAmount, volumeAdded)`  
   只有执行者。一次归还结清整笔未还金额，可以少还，也可以还 0。少掉的部分立刻记成已实现亏损，不能事后再补。`volumeAdded` 是执行者自己申报的成交量，合约不核验外部订单。累计申报达到 `volumeTarget` 后不能再支取；累计亏损达到 `maxLoss` 后也不能再支取。
5. `pause` / `unpause`  
   只有所有者。不移动资金。暂停时仍可归还。
6. `close`  
   只有所有者。把**仍在这张策略托管里**的代币退回所有者。已经支取且还没归还的代币在执行者手里，`close` 追不回来。关闭之后如果执行者再归还，代币会直接转给所有者，不会锁在已关闭的策略里。

`getPolicy` 返回策略、双方 handle，以及状态：进行中、已暂停、已到期、已关闭、成交量已达标、已达亏损上限。关闭优先于其他状态。

直接把代币转到合约地址不会记入任何策略，也没有人能取回。请只调用 `deposit`。合约拒绝接收原生币。

## 权限披露

这份合约**没有**所有者、管理员、升级代理、全局暂停或救援函数。部署者不能提取任何用户的托管。

| 函数 | 谁可以调用 | 会不会动托管 |
| --- | --- | --- |
| `createPolicy` | 持有 Agent ID 的地址，且执行者也持有 | 否 |
| `deposit` | 该策略所有者 | 增加该策略托管 |
| `pull` | 该策略执行者，且规则允许 | 把代币转给执行者 |
| `repay` | 该策略执行者，且有未结清支取 | 还回托管；若已关闭则转给所有者 |
| `pause` / `unpause` | 该策略所有者 | 否 |
| `close` | 该策略所有者 | 剩余托管只退给该所有者 |

没有第二套隐藏入口。测试里的 `MockAgentRegistry` 和 `MockUSDT` 谁都可以铸币、登记 handle，它们只用于本地，`DeployLocal` 会拒绝 chain id 56 和 97。

## 风险

- 执行者按规则取出的代币已经离开合约。他不还，合约没有办法代你要回。最大亏损是这种不归还金额的累计上限，不是保本承诺。
- 归还金额小于未结清支取时，差额马上记成亏损。
- 成交量是执行者填的。它只用来在达到目标后停止继续支取，不能当成真实成交证明。
- 代币本身可能被发行方冻结或列入名单。那是代币的风险，合约不会因此把资金改送到别的地址。
- 不提供收益、被动收入或自动赚钱。交易有损失本金的可能。

## 本地测试

需要 [Foundry](https://book.getfoundry.sh/getting-started/installation) 和 Node.js 22+。

```bash
forge test
```

覆盖的路径包括：创建、精确授权、存入、支取、归还；没有 Agent ID 的人不能创建；超过单笔上限、有未结清支取时再次支取、达到亏损上限、到期、关闭、暂停都会拒绝支取；只有所有者能暂停和关闭；只有执行者能支取和归还；关闭只退回剩余托管；无限授权和多余授权都不能存入；归还后授权额度为 0。另外还有重入、无返回值代币、返回 `false` 的代币，以及到账数量不足时回滚。

本地页面：

```bash
anvil --host 127.0.0.1 --port 8545 --chain-id 31337
./script/deploy-local.sh
cd frontend
npm install
npm run dev
```

`deploy-local.sh` 使用节点上已解锁的默认开发账户 `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`，命令里没有私钥。Anvil 会在自己的终端打印开发账户。只把那个账户导入你自己的本地钱包，用来操作这台本机节点。不要把它用到其他网络，也不要写进仓库。

全新节点上，上面这个账户的前三笔创建交易地址是：

| 合约 | 地址 |
| --- | --- |
| 测试用 Agent ID 登记表 | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| 测试代币（18 位小数） | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |
| AgentPolicyDesk | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` |

`frontend/public/config.json` 里链 31337 已填这三份地址。部署日志如果不同，在页面里覆盖。部署脚本会给发送者登记 handle `880`，并铸造测试代币。页面在链 31337 上还可以给当前地址登记演示 handle、领取测试币。这些按钮在链 56 上不会出现。

打开页面后：连接钱包，切到本地链，创建策略，按输入金额授权再存入，用执行者支取再归还，最后由所有者关闭。每一步都是钱包自己弹出的确认。

## 部署到链 56 并在 BscScan 开源验证

不要把私钥、keystore 或 BscScan API key 提交到仓库。下面的命令不会在这个项目的测试里执行。

```bash
cast wallet import deployer --interactive

export AGENT_REGISTRY=0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F
export USDT=0x55d398326f99059fF775485246999027B3197955
export BSC_RPC=https://bsc-dataseed.bnbchain.org
export BSCSCAN_API_KEY=你自己的密钥

forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$BSC_RPC" \
  --account deployer \
  --broadcast \
  --slow \
  --verify \
  --etherscan-api-key "$BSCSCAN_API_KEY"
```

`Deploy` 只接受 chain id 56。构造参数就是上面两个地址，部署者不会因此得到任何管理权限。部署完成后，把打出来的合约地址填进 `frontend/public/config.json` 的链 56 `policyDesk`，或填进页面的本机配置。

如果自动验证失败，可以手动在 BscScan 提交源码：

```bash
forge flatten src/AgentPolicyDesk.sol > AgentPolicyDesk.flat.sol
cast abi-encode "constructor(address,address)" "$AGENT_REGISTRY" "$USDT"
```

验证设置：Solidity `0.8.26+commit.8a97fa7a`，优化打开，runs `200`，EVM `cancun`，不使用 via IR，许可证 MIT。扁平化文件的合约名选 `AgentPolicyDesk`。

## 前端

`frontend/` 是 Vite 静态页面，只用 `window.ethereum`。没有服务器，没有会话存储，没有二维码或配对码登录。钱包地址覆盖项存在浏览器 `localStorage`，只包括合约地址。

```bash
cd frontend
npm install
npm run dev
```

开发服务器是 `http://127.0.0.1:43123`。`npm run build` 会做类型检查并生成 `frontend/dist`。

## 安全边界

- 不提供 Agentic Wallet 的网页扫码或配对码登录，不在服务器保存登录态或代客下单。
- 授权和转账都由用户在钱包里确认。页面不会请求无限授权。
- 没有定时任务把资金扫到固定地址，也没有管理员可以转走托管。
- 不收集助记词、私钥、PIN、API 密钥或配对码。
- 不把 Agent ID 做成按名字查询他人钱包的工具。
- 不承诺收益。交易风险提示固定显示在页面上。

## 文件

```text
src/AgentPolicyDesk.sol          不可升级的策略合约
src/interfaces/                  登记表与代币的最小接口
src/libraries/SafeToken.sol      检查 ERC-20 返回值
script/Deploy.s.sol              仅 chain id 56
script/DeployLocal.s.sol         本地测试替身，拒绝 56 和 97
script/deploy-local.sh           用已解锁账户部署，不含私钥
test/                            Foundry 测试与本地替身
frontend/                        中文静态页面
lib/forge-std/                   Foundry 标准库（MIT）
```

---

# English

AgentPolicyDesk is an on-chain policy desk. A wallet that holds an Agent ID writes trading limits and may escrow the configured token. Only the bound executor, who must also hold an Agent ID at creation, can pull funds, and only inside those limits. The owner can pause or close and withdraw whatever escrow is still in the contract.

The first intended user is Agent 880 (handle `880`). The contract does not hardcode that handle. Any address with `balanceOf > 0` on the registry can create a policy or be bound as executor.

## How Agent ID is used

Official registry on chain id 56: `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`.

`balanceOf(account) > 0` is the eligibility check, applied to both the owner and the executor inside `createPolicy`. `handleOf` is display-only. Handles are shown without an `.ai` suffix. Later calls trust the addresses stored on the policy, so the owner can still close and the executor can still repay if the registry cannot be read. Agent IDs on this registry are soulbound, so an address that passed the check keeps the id.

There is no handle-to-wallet search. The page shows the connected wallet's own handle, plus the two parties of a policy you already have open.

## Rules

Token amounts are raw base units. The target token is USDT `0x55d398326f99059fF775485246999027B3197955` (18 decimals).

- `maxPerTrade`, `volumeTarget`, and `maxLoss` must be non-zero. Expiry must be in the future.
- Deposit allowance must equal the deposit amount. Unlimited allowance is rejected.
- One outstanding pull at a time. One `repay` settles it. A smaller repay, including zero, realizes the difference as loss immediately.
- Reported volume is the executor's number. The contract does not verify external trades. Reaching `volumeTarget` or `maxLoss` blocks further pulls.
- `close` returns only this policy's remaining escrow to its owner. Pulled tokens that were not repaid stay with the executor. A repay after close is forwarded to the owner instead of being locked.
- Direct token transfers to the contract are not credited and there is no rescue function. That is deliberate: a rescue would be an admin sweep. The contract also rejects native coins.
- Paused policies can still receive deposits and repays. They cannot be pulled.

`getPolicy` returns the policy, both handles, and a status. Closed wins over completed, loss limit, expiry, and pause.

## Permissions

There is no contract owner, no admin, no proxy, no global pause, and no function that pays the deployer. The only privileged calls are per policy:

| Call | Who | Funds |
| --- | --- | --- |
| `createPolicy` | Agent ID holder, binding another Agent ID holder | none |
| `deposit` | that policy's owner | increases that policy's escrow |
| `pull` | that policy's executor, inside the rules | sends tokens to the executor |
| `repay` | that policy's executor, when a pull is outstanding | back to escrow, or to the owner if already closed |
| `pause`, `unpause` | that policy's owner | none |
| `close` | that policy's owner | remaining escrow returns only to that owner |

`MockAgentRegistry` and `MockUSDT` are permissionless test doubles. `DeployLocal` refuses chain ids 56 and 97. Do not deploy them on a public network.

## Risk

Pulled tokens leave the contract. If the executor does not repay, the contract cannot recover them. `maxLoss` is the cumulative cap on that shortfall, not a promise that funds are safe. Recorded volume is self-reported. The token issuer may still freeze balances. This project does not offer yield, passive income, or automatic profit. Trading can lose the escrowed amount.

## Test

Foundry:

```bash
forge test
```

The suite covers the happy path, missing Agent ID, pulls over the per-trade cap, a second pull while one is outstanding, pulls after the loss limit, expiry, close, and pause, owner-only pause and close, executor-only pull and repay, close returning only remaining escrow, and exact-allowance checks with no standing unlimited approval. It also covers reentrancy, tokens that return no bool, tokens that return false, and short deliveries.

## Local demo

```bash
anvil --host 127.0.0.1 --port 8545 --chain-id 31337
./script/deploy-local.sh
cd frontend && npm install && npm run dev
```

The shell script broadcasts through an unlocked development account. It does not contain a private key. Anvil prints development accounts in its terminal. Import one into a wallet only for this local node. Do not reuse it elsewhere and do not commit it.

On a fresh node, the first three creates from `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` are the addresses already stored for chain 31337 in `frontend/public/config.json`:

- registry `0x5FbDB2315678afecb367f032d93F642f64180aa3`
- test token `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512`
- desk `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0`

If the deploy log differs, paste those addresses into the page. They stay in browser local storage only. Chain 56 local tools (mock registration and mint) are hidden. The dev server is [http://127.0.0.1:43123](http://127.0.0.1:43123).

## Deploy on chain 56 and verify

Do not commit a keystore, a private key, or a BscScan API key. This repository does not run the deploy.

```bash
cast wallet import deployer --interactive
export AGENT_REGISTRY=0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F
export USDT=0x55d398326f99059fF775485246999027B3197955
export BSC_RPC=https://bsc-dataseed.bnbchain.org

forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$BSC_RPC" \
  --account deployer \
  --broadcast \
  --slow \
  --verify \
  --etherscan-api-key "$BSCSCAN_API_KEY"
```

`Deploy` reverts unless the chain id is 56. The constructor arguments are the registry and the token. The deployer gains no admin role. After deployment, put the new address in the chain 56 `policyDesk` field.

Manual verification if the API path fails:

```bash
forge flatten src/AgentPolicyDesk.sol > AgentPolicyDesk.flat.sol
cast abi-encode "constructor(address,address)" "$AGENT_REGISTRY" "$USDT"
```

Compiler `0.8.26+commit.8a97fa7a`, optimizer on, 200 runs, EVM `cancun`, via IR off, license MIT. Select contract `AgentPolicyDesk` in the flattened file.

## Frontend and safety limits

The site is a static Vite app. It talks only to `window.ethereum`. There is no backend, no stored wallet session, no QR or pairing-code login, and no request for a seed phrase, private key, PIN, or API secret. Every approval and transfer is a wallet confirmation. Approvals are for the exact amount of that action. There is no scheduled sweep. The trading-risk notice stays on the page. Agent ID is not a lookup tool for other people's wallets.
