# Ranked 通关时间 / delta 结算 / lv6 通关画面 / lv3 乘法宝藏 / 单人模式 实现计划

## 概述
针对 `ranked.html` 排位模式做一批修复与增强，共 6 项需求 + 新增单人（singleplayer）玩法：
1. 游戏结束后显示通关时间
2. 修复结算页 delta 恒为 0 的问题
3. 胜利者进入 endportal 后，victory 画面（终末之诗 + CONGRATULATIONS + 公式飞出）直接在 lv6 页面显示
4. ranked lv3 第三个宝藏（obsidian）改为 `(a+bi)(c+di)` 乘法形式，让玩家算乘法找坐标
5. 结算页 "Rating" → "Elo"，"Δ 多少" → "+/- 多少"
6. 新增 singleplayer 玩法：自己玩算通关时间，分数按给定公式计入 Elo

## 现状分析（已读代码确认）
- `finalizeMatch`（ranked.html:720-748）会写 `host_rating_delta` / `guest_rating_delta`，但 `ranked_matches` 表**缺少这两个列**，导致 `.update()` 静默失败（未检查 error），`winner_id` 由 onLv6Done 内单独一条 `.update` 写入所以胜/负判定仍正确，但 delta 读出来是 `undefined` → 显示 0。这是 item 2 的根因。
- `showResult`（ranked.html:689-717）第 703 行当前文案为 `"Rating: ... (Δ +x)"`，需改文案与符号。
- lv6 的 `checkPortalCollision`（ranked.html:1647）到达传送门 2s 后**直接调用 `window.onLv6Done()`**，跳过了已定义但从未被调用的 `showEndPoem()` / `showWinOverlay()`（ranked.html:1703-1718 / 1657-1663），所以胜利画面没在 lv6 上显示。
- `genTreasureCoords(seed)`（ranked.html:326-341）为三个宝藏统一生成随机坐标；`updateCompassTooltip`（ranked.html:2180-2197）对 digStage<2 与 digStage===2 显示完全相同的相对坐标文本。第三个宝藏需要改为乘法形式。
- `startMatch()`（ranked.html:573-586）是 PvP 比赛入口；lv3/lv6 完成分别通过 `window.onLv3Done`（632）/`window.onLv6Done`（643）/`window.onRankedLost`（660）挂钩。
- 大厅操作区 HTML：ranked.html:27-31（`lobby-actions` 内含 CREATE ROOM / JOIN ROOM）。

## 具体改动

### A. 数据库（Supabase SQL Editor 执行一次）
为 `ranked_matches` 补齐两个 delta 列（item 2 根因修复）。无需新增表。

```sql
alter table public.ranked_matches
  add column if not exists host_rating_delta integer,
  add column if not exists guest_rating_delta integer;

notify pgrst, 'reload schema';
```

### B. ranked.html — 外层 IIFE（大厅/Elo/结算作用域）

**B1. 新增模块级变量**（约 ranker.html:344-352 附近，`let myPhase = "lv3";` 之后）：
```js
let matchStartTime = null;
let myClearTime = null;
let soloMode = false;
```

**B2. `startMatch()`（573-586）**：函数开头加 `matchStartTime = performance.now();` 并 `soloMode = false;`。

**B3. `genTreasureCoords(seed)`（326-341）重写**：前两个宝藏仍用随机点；第三个宝藏用复数乘法生成，并把因子附到对象上：
```js
function genTreasureCoords(seed) {
    const rng = mulberry32(Number(seed) & 0xFFFFFFFF);
    const used = {};
    const vals = [-3, -2, -1, 1, 2, 3];
    function nextPoint() {
        while (true) {
            const x = Math.floor(rng() * 37) - 18;
            const y = Math.floor(rng() * 37) - 18;
            if (x === 0 && y === 0) continue;
            if (x === 6 && y === -8) continue;
            const k = x + "," + y;
            if (used[k]) continue;
            used[k] = true;
            return { x: x, y: y };
        }
    }
    const coords = [nextPoint(), nextPoint()];
    while (true) {
        const a = vals[Math.floor(rng() * vals.length)];
        const b = vals[Math.floor(rng() * vals.length)];
        const c = vals[Math.floor(rng() * vals.length)];
        const d = vals[Math.floor(rng() * vals.length)];
        const x = a * c - b * d;   // 实部 ac - bd
        const y = a * d + b * c;   // 虚部 ad + bc
        if (x === 0 && y === 0) continue;
        if (x === 6 && y === -8) continue;
        if (x < -18 || x > 18 || y < -18 || y > 18) continue;
        const k = x + "," + y;
        if (used[k]) continue;
        used[k] = true;
        coords.push({ x: x, y: y, factors: { a: a, b: b, c: c, d: d } });
        break;
    }
    return coords;
}
```

**B4. 单人分数公式与结算辅助函数**（放在 Elo 函数附近，约 313 行后）：
```js
function computeSoloScore(T) {
    const T_fast = 120, tau = 60;
    if (T <= T_fast) return 40;
    const raw = 20 + 20 * Math.exp(-(T - T_fast) / tau);
    return Math.round(Math.min(40, Math.max(20, raw)));
}
function fmtTime(sec) {
    const s = Math.round(sec);
    const m = Math.floor(s / 60);
    const r = s % 60;
    return m > 0 ? m + "m " + r + "s" : r + "s";
}
```

**B5. `onLv3Done()`（632-641）**：加单人分支（跳过 DB progress）：
```js
window.onLv3Done = function () {
    if (myPhase !== "lv3") return;
    myPhase = "lv6";
    if (!soloMode) updateMyProgress({ phase: "lv6" });
    window.__activePhase = "lv6";
    $("phase-lv3").style.display = "none";
    $("phase-lv6").style.display = "block";
    if (window.__rankedStartLv6) window.__rankedStartLv6();
    updateProgressBar();
};
```

**B6. `onLv6Done()`（643-658）**：开头记录通关时间，并加单人分支：
```js
window.onLv6Done = async function () {
    if (myPhase !== "lv6") return;
    myPhase = "done";
    window.__activePhase = null;
    const clearSec = (performance.now() - (matchStartTime || performance.now())) / 1000;
    if (soloMode) { await finishSolo(clearSec); return; }
    myClearTime = clearSec;
    // ……保留原有 PvP 逻辑（stopPoll / showResultPlaceholder / updateMyProgress / finalizeMatch / showResult）
};
```

**B7. `onRankedLost()`（660-680）**：开头加单人分支：
```js
window.onRankedLost = async function (phase) {
    if (soloMode) { showSoloFail(); return; }
    // ……保留原有 PvP 逻辑
};
```

**B8. `showResult()`（689-717）**：改文案（item 5）与通关时间显示（item 1）。
把第 703 行改为：
```js
const deltaStr = (delta >= 0 ? "+" : "") + (delta || 0);
var lines = [
    "Elo: " + oldRating + " → " + newR + "  (" + deltaStr + ")",
    "Rank: " + rankHtml(oldRating) + " → " + rankHtml(newR)
];
if (myClearTime != null) lines.push("Clear Time: " + fmtTime(myClearTime));
```

**B9. 单人玩法函数**（新增，放在 `onRankedLost` 之后）：
```js
function startSolo() {
    stopPoll();
    soloMode = true;
    roomCode = null; mySide = null; matchRow = null;
    myClearTime = null;
    matchStartTime = performance.now();
    myPhase = "lv3";
    window.__activePhase = "lv3";
    $("ranked-progress").style.display = "none";
    $("phase-lv3").style.display = "block";
    $("phase-lv6").style.display = "none";
    const seed = Math.floor(Math.random() * 9007199254740991);
    if (window.__rankedInitLv3) window.__rankedInitLv3(seed);
    if (window.__rankedCenterLv3) window.__rankedCenterLv3();
    if (window.__rankedLv3Tips) window.__rankedLv3Tips();
    showView("view-match");
}

async function finishSolo(clearSec) {
    const score = computeSoloScore(clearSec);
    let oldRating = myRating;
    if (supabaseClient && currentUserId) {
        const { data } = await supabaseClient.from("ranked_profiles").select("rating, games").eq("id", currentUserId).maybeSingle();
        if (data) {
            oldRating = data.rating != null ? data.rating : myRating;
            const games = (data.games || 0) + 1;
            const newRating = oldRating + score;
            await supabaseClient.from("ranked_profiles").upsert({
                id: currentUserId,
                rating: newRating,
                games: games,
                updated_at: new Date().toISOString()
            });
            myRating = newRating;
        }
    }
    $("result-title").textContent = "CLEARED!";
    $("result-title").style.color = "#ffff55";
    $("result-body").innerHTML = "";
    [
        "Clear Time: " + fmtTime(clearSec),
        "Score: +" + score,
        "Elo: " + oldRating + " → " + myRating
    ].forEach(function (t) {
        const d = document.createElement("div");
        d.className = "ranked-text";
        d.textContent = t;
        $("result-body").appendChild(d);
    });
    showView("view-result");
}

function showSoloFail() {
    myPhase = "done";
    $("ranked-progress").style.display = "";
    $("result-title").textContent = "DEFEAT!";
    $("result-title").style.color = "#ff5555";
    $("result-body").innerHTML = "";
    showView("view-result");
}
```

**B10. 大厅按钮**（ranked.html:27-31 `lobby-actions` 内加一个按钮）：
```html
<button id="solo-btn" type="button"><span>PLAY SOLO</span></button>
```

**B11. 事件绑定**（ranked.html:784 附近）：
```js
$("solo-btn").addEventListener("click", startSolo);
```

**B12. 结算回退按钮**（`result-back-btn`，ranked.html:54）：由 inline onclick 改为 JS 绑定，单人模式返回大厅、PvP 返回首页。给按钮去掉 inline `onclick`，在事件绑定区加：
```js
$("result-back-btn").addEventListener("click", function () {
    if (soloMode) { soloMode = false; $("ranked-progress").style.display = ""; renderLobby(); }
    else window.location.href = 'index.html';
});
```

### C. ranked.html — lv6 IIFE（打龙作用域）

**C1. 通关画面（item 3）**：把 `checkPortalCollision`（ranked.html:1647）里直接 `onLv6Done` 改为先放终末之诗：
```js
if (performance.now() - portalDwellStart >= 2000) { showEndPoem(); }
```

**C2.** `showWinOverlay()`（1657-1663）末尾补一句延迟结算，让 victory 画面先在 lv6 展示数秒后自动结算：
```js
function showWinOverlay() {
    if (winShown || hasFailed) return;
    winShown = true;
    persistLevel6Passed();
    winOverlay.classList.add('show');
    startFormulaFountain();
    setTimeout(function () { if (window.onLv6Done) window.onLv6Done(); }, 2500);
}
```

### D. ranked.html — lv3 IIFE（挖宝作用域）

**D1. 宝藏因子透传**：`__rankedInitLv3`（2715-2723）把因子存到宝藏对象：
```js
window.__rankedInitLv3 = function (seed) {
    const coords = window.genTreasureCoords(seed);
    treasures.forEach((t, i) => {
        t.x = coords[i].x;
        t.y = coords[i].y;
        t.factors = coords[i].factors || null;
        t.el.style.left = `calc(50% + ${t.x * unitPx}px)`;
        t.el.style.top = `calc(50% - ${t.y * unitPx}px)`;
    });
};
```

**D2. 乘法文案（item 4）**：新增紧凑因子格式化助手，并改 `updateCompassTooltip`（2180-2197）的 obsidian 分支：
```js
function formatFactor(real, imag) {
    return '(' + real + (imag >= 0 ? '+' : '-') + Math.abs(imag) + 'i)';
}

function updateCompassTooltip() {
    if (selectedSlot !== 0) return;
    const playerRe = posX / unitPx;
    const playerIm = -posY / unitPx;
    if (digStage < 2) {
        const t = treasures[digStage];
        const relRe = t.x - playerRe;
        const relIm = t.y - playerIm;
        compassTooltip.textContent =
            `The ${t.word} treasure is relative (${formatComplexCoord(Math.round(relRe), Math.round(relIm))}) to you!`;
    } else {
        const t = treasures[digStage];
        if (t.factors) {
            const f = t.factors;
            compassTooltip.textContent = "The " + t.word + " treasure is at " + formatFactor(f.a, f.b) + formatFactor(f.c, f.d) + ".";
        } else {
            const relRe = t.x - playerRe;
            const relIm = t.y - playerIm;
            compassTooltip.textContent =
                `The ${t.word} treasure is relative (${formatComplexCoord(Math.round(relRe), Math.round(relIm))}) to you!`;
        }
    }
}
```

## 假设与决策
- **通关时间**：PvP 采用胜方客户端本地计时（`startMatch()` 到进入 endportal 完成通关），仅胜方结算页显示；单人模式全程显示。不做跨端时间同步，避免与 delta 结算的竞态。
- **单人分数性质**：`score ∈ [20, 40]` 直接作为 Elo 增量加入 `ranked_profiles.rating`（`rating += score`），并 `games += 1`；胜负字段（wins/losses）不变。这与用户「并入 Elo 体系」的确认一致。
- **单人宝藏/打龙逻辑**：完全复用现有 lv3/lv6 阶段，仅通过 `soloMode` 分支跳过 PvP 的 `ranked_matches` 读写。
- **第三个宝藏因子**：`a,b,c,d ∈ {-3,-2,-1,1,2,3}`（均非 0），乘积实部/虚部自然落在 ±18 内；再过滤原点/传送门(6,-8)/与另两个宝藏重复。
- **级联失败分支原本独立于本次修复之外**（如 pollWaiting 中 `status === "finished"` 调 startMatch 疑似笔误），不在本次改动范围。

## 验证步骤
1. 在 Supabase SQL Editor 执行 A 段 SQL，确认两列已加。
2. 双账号 PvP 完整打一局：
   - 胜方进入 endportal 后应看到终末之诗 → CONGRATULATIONS + 公式飞出（lv6 页面内），约 2.5s 后自动进入结算。
   - 结算页标题为 VICTORY!/DEFEAT!，显示 `Elo: 旧 → 新 (+Z)`（输方为 `-Z`），delta 不再是 0；胜方多一行 `Clear Time: Xs`。
3. ranked lv3：选中罗盘（槽位 1）挖到第三个宝藏时，提示应显示 `The final treasure is at (a+bi)(c+di).`，且实测该乘积等于宝藏真实坐标（可挖中）。
4. 大厅点 `PLAY SOLO`：不建房直接进 lv3 → lv6 → 通关，结算页显示 `Clear Time` / `Score: +Z` / `Elo: 旧 → 新`；分数随通关时间按公式在 20~40 之间（≤120s 恒为 40）。
5. 确认单人模式下顶部 `You:/Opponent:` 进度条被隐藏，BACK 返回大厅。