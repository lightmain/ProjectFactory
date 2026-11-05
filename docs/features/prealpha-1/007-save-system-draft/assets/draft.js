/* Product-document illustration only. No game integration or persistent storage. */
(function () {
  "use strict";
  const byId = (id) => document.getElementById(id);
  const types = { manual: "手动", auto: "自动", exit: "退出" };
  let worlds, records, active, resume, selected, serial, pending;
  const nameKey = (name) => name.trim().normalize("NFC").toLowerCase();
  const find = (id) => records.find((record) => record.id === id);
  const worldName = (id) => worlds.find((world) => world.id === id)?.name || "已删除世界";
  const nameValid = (name) => Array.from(name.trim()).length >= 1 &&
    Array.from(name.trim()).length <= 64 && !/[\u0000-\u001f\u007f-\u009f]/u.test(name);
  const manualNamed = (world, name) => records.find((record) =>
    record.world === world && record.type === "manual" && nameKey(record.name) === nameKey(name));
  function uniqueName(base, world = active?.world) {
    let result = base, index = 2;
    while (manualNamed(world, result)) result = `${base} ${index++}`;
    return result;
  }
  function feedback(message, error = false) {
    byId("demo-feedback").textContent = message;
    byId("demo-feedback").classList.toggle("error", error);
    const item = document.createElement("li");
    item.textContent = message;
    byId("demo-log").prepend(item);
    while (byId("demo-log").children.length > 14) byId("demo-log").lastChild.remove();
  }
  function closeConfirm() {
    pending = false;
    byId("demo-confirm").hidden = true;
    byId("demo-conflict-label").hidden = true;
    byId("demo-options").replaceChildren();
    render();
  }
  function confirm(message, options) {
    pending = true;
    byId("demo-conflict-label").hidden = true;
    byId("demo-question").textContent = message;
    byId("demo-options").replaceChildren();
    options.forEach(([label, action, style]) => {
      const button = document.createElement("button");
      button.textContent = label;
      if (style) button.className = style;
      button.addEventListener("click", action);
      byId("demo-options").append(button);
    });
    byId("demo-confirm").hidden = false;
    render();
  }
  function render() {
    const previousWorld = byId("demo-world").value;
    const available = worlds.filter((world) => records.some((record) => record.world === world.id) || active?.world === world.id);
    byId("demo-world").replaceChildren();
    available.forEach((world) => byId("demo-world").add(new Option(world.name, world.id)));
    if (!available.length) byId("demo-world").add(new Option("没有存档世界", ""));
    byId("demo-world").value = available.some((world) => world.id === previousWorld) ? previousWorld :
      active?.world || available[0]?.id || "";
    const target = active?.target ? find(active.target) : null;
    const continuing = resume ? find(resume.id) : null;
    byId("demo-status").textContent = [
      active ? `运行世界：${worldName(active.world)}｜累计 ${active.tick} 分钟` : "当前在主菜单，没有运行世界",
      `手动目标：${target?.name || "未指定"}`,
      active ? `载入来源：${active.sourceName || "新开局"}${active.source && !find(active.source) ? "（来源已删除）" : ""}｜${active.unprotected ? "恢复快照已删除，请重新保存" : active.dirty ? "有未保存进度" : "暂无新增未保存进度"}` : "",
      `继续目标：${continuing ? `${worldName(continuing.world)} / ${continuing.name} / ${continuing.time}` : resume ? "原引用已失效，请另选" : "尚无成功快照"}`
    ].filter(Boolean).join("；");
    const browsing = byId("demo-world").value;
    const filter = byId("demo-filter").value;
    const search = nameKey(byId("demo-search").value);
    const visible = records.filter((record) => record.world === browsing &&
      (filter === "all" || record.type === filter) && nameKey(record.name).includes(search))
      .sort((left, right) => right.order - left.order);
    byId("demo-rows").replaceChildren();
    if (!visible.length) {
      const message = document.createElement("p");
      message.className = "small";
      message.textContent = "没有匹配的存档。可以清除筛选，或在当前运行世界创建第一份保存。";
      byId("demo-rows").append(message);
    }
    visible.forEach((record) => {
      const row = document.createElement("button");
      row.className = "save-row";
      row.setAttribute("aria-pressed", String(record.id === selected));
      row.disabled = pending;
      const title = document.createElement("span");
      const strong = document.createElement("strong");
      strong.textContent = record.name;
      const small = document.createElement("small");
      small.textContent = `${record.time} · 游戏 ${record.tick} 分钟 · 示例版本 prealpha-1` +
        (record.id === active?.target ? " · 当前手动目标" : "") +
        (record.id === resume?.id ? " · 继续目标" : "") +
        (record.backup ? " · 有恢复版本" : "");
      title.append(strong, small);
      const type = document.createElement("span");
      type.className = "type";
      type.textContent = types[record.type];
      row.append(title, type);
      row.addEventListener("click", () => {
        selected = record.id;
        if (record.type === "manual") byId("demo-name").value = record.name;
        render();
      });
      byId("demo-rows").append(row);
    });
    const chosen = find(selected);
    ["demo-save", "demo-save-as", "demo-quick", "demo-progress", "demo-auto", "demo-leave"].forEach((id) => {
      byId(id).disabled = pending || !active;
    });
    byId("demo-new").disabled = pending;
    byId("demo-continue").disabled = pending || !continuing;
    byId("demo-load").disabled = pending || !chosen;
    byId("demo-delete").disabled = pending || !chosen;
    byId("demo-rename").disabled = pending || chosen?.type !== "manual";
    byId("demo-restore").disabled = pending || !chosen?.backup;
    ["demo-world", "demo-filter", "demo-search", "demo-name"].forEach((id) => { byId(id).disabled = pending; });
  }
  function reset() {
    worlds = [{ id: "north", name: "北部工厂" }, { id: "lab", name: "沙盒测试" }];
    records = [
      { id: "a", world: "north", name: "扩建前", type: "manual", tick: 30, time: "14:00", order: 1 },
      { id: "b", world: "north", name: "扩建后", type: "manual", tick: 70, time: "14:40", order: 2 },
      { id: "c", world: "north", name: "自动保存 1", type: "auto", tick: 75, time: "14:45", order: 3 },
      { id: "d", world: "lab", name: "运输实验", type: "manual", tick: 12, time: "14:50", order: 4 }
    ];
    active = { world: "north", target: "a", source: "a", sourceName: "扩建前", persisted: "a", tick: 32, dirty: true };
    resume = { id: "a", world: "north" };
    selected = "a"; serial = 5; pending = false;
    byId("demo-world").replaceChildren();
    worlds.forEach((world) => byId("demo-world").add(new Option(world.name, world.id)));
    byId("demo-world").value = "north";
    byId("demo-filter").value = "all";
    byId("demo-search").value = "";
    byId("demo-name").value = "扩建前";
    byId("demo-fail").checked = false;
    byId("demo-log").replaceChildren();
    closeConfirm();
    feedback("示例复位：已载入扩建前 A，新增 2 分钟。较晚的 B 和自动档 C 仍在，但继续目标是 A。");
  }
  function write(type, name, existing) {
    if (byId("demo-fail").checked) {
      byId("demo-fail").checked = false;
      feedback("模拟磁盘满：保存失败。旧档、手动目标、继续引用和当前现场均未改变。", true);
      return false;
    }
    const id = existing?.id || `save-${serial}`;
    const record = { id, world: active.world, name, type, tick: active.tick,
      time: `示例成功时刻 ${serial}`, order: serial++ };
    if (existing && type === "manual") record.backup = { ...existing, backup: undefined };
    records = records.filter((previous) => previous.id !== id);
    records.push(record);
    if (type === "auto") {
      const autos = records.filter((entry) => entry.world === active.world && entry.type === "auto")
        .sort((left, right) => right.order - left.order);
      const obsolete = autos.slice(3).map((entry) => entry.id);
      records = records.filter((entry) => !obsolete.includes(entry.id));
    }
    if (type === "manual") active.target = id;
    active.dirty = false;
    active.unprotected = false;
    active.persisted = id;
    resume = { id, world: active.world };
    selected = id;
    byId("demo-world").value = active.world;
    byId("demo-filter").value = "all";
    byId("demo-search").value = "";
    feedback(`${types[type]}保存成功：${name}。继续引用已更新${type === "manual" ? "，手动目标已绑定此档" : "，手动目标不变"}。`);
    return true;
  }
  function save() {
    const name = byId("demo-name").value.trim();
    if (!nameValid(name)) { feedback("名称需为 1–64 个字符，不得包含控制字符或仅空白。", true); return; }
    const existing = manualNamed(active.world, name);
    if (!existing) { write("manual", name); render(); return; }
    confirm(`覆盖“${worldName(active.world)} / ${existing.name}”（${existing.time}，游戏 ${existing.tick} 分钟）？成功后保留一次恢复版本。`, [
      ["确认覆盖", () => { write("manual", name, existing); closeConfirm(); }, "primary"],
      ["取消覆盖", () => { closeConfirm(); feedback("已取消覆盖，旧档和现场未改变。"); }]
    ]);
  }
  function load(id) {
    const record = find(id);
    if (!record) { feedback("目标已缺失，保留原现场并刷新列表。", true); return; }
    active = { world: record.world, target: record.type === "manual" ? record.id : null,
      source: record.id, sourceName: record.name, persisted: record.id, tick: record.tick, dirty: false };
    resume = { id: record.id, world: record.world };
    selected = record.id;
    byId("demo-world").value = record.world;
    byId("demo-name").value = record.type === "manual" ? record.name : uniqueName("新手动存档", record.world);
    feedback(`已读取 ${record.name}，恢复到游戏 ${record.tick} 分钟。继续引用指向此档；${record.type === "manual" ? "手动目标绑定此档" : "手动目标为空，首次保存需命名"}。`);
    render();
  }
  function leaveGate(label, action, loadTarget = null) {
    if (!active) { action(); return; }
    const destination = loadTarget && find(loadTarget);
    const conflict = destination?.type === "exit" && destination.world === active.world;
    const description = active.unprotected ? "当前现场的恢复快照已删除，请重新保存。" :
      active.dirty ? "当前有未保存进度。" : "暂无新增未保存进度；手动目标未必已更新。";
    const message = conflict ? "目标是本世界旧退出档；保存选项改为手动另存，保留原读取时间点。请确认下方新名称。" :
      "保存选项写独立退出档，不覆盖手动档。";
    const options = [
      [conflict ? "另存当前现场并读取" : "保存并继续此操作", () => {
        if (conflict) {
          const name = byId("demo-conflict-name").value.trim();
          if (!nameValid(name) || manualNamed(active.world, name)) {
            feedback("示例要求不冲突的新手动名；无效或重名时保留保护页，请修改名称。", true); return;
          }
          if (!write("manual", name)) return;
          closeConfirm(); action(); render(); return;
        }
        const prior = records.find((record) => record.world === active.world && record.type === "exit");
        if (!write("exit", "退出保存", prior)) return;
        closeConfirm(); action(); render();
      }, "primary"],
      ["不保存并继续此操作", () => { closeConfirm(); feedback("选择不保存：未写入任何新快照。"); action(); render(); }],
      ["取消", () => { closeConfirm(); feedback("已取消离开，保留原暂停现场。"); }]
    ];
    confirm(`${description} ${label}前如何处理？${message}`, options);
    if (conflict) {
      byId("demo-conflict-name").value = uniqueName("读取前留档");
      byId("demo-conflict-label").hidden = false;
    }
  }
  byId("demo-world").addEventListener("change", () => { selected = null; render(); });
  byId("demo-filter").addEventListener("change", render);
  byId("demo-search").addEventListener("input", render);
  byId("demo-save").addEventListener("click", save);
  byId("demo-save-as").addEventListener("click", () => {
    byId("demo-name").value = uniqueName("新方案");
    byId("demo-world").value = active.world;
    feedback("另存为：已填写不冲突新名称。修改后点击保存游戏，旧手动档保持原样。");
    render(); byId("demo-name").focus();
  });
  byId("demo-quick").addEventListener("click", () => {
    const target = active.target && find(active.target);
    if (target) { write("manual", target.name, target); render(); }
    else {
      byId("demo-name").value = uniqueName("新手动存档");
      byId("demo-world").value = active.world;
      feedback("尚无手动目标：请命名并点击保存游戏，不会自动覆盖旧手动档。");
      render(); byId("demo-name").focus();
    }
  });
  byId("demo-load").addEventListener("click", () => {
    const id = selected;
    leaveGate("读取所选存档", () => load(id), id);
  });
  byId("demo-continue").addEventListener("click", () => {
    const id = resume?.id;
    leaveGate("读取继续引用", () => load(id), id);
  });
  byId("demo-progress").addEventListener("click", () => {
    active.tick += 2; active.dirty = true;
    feedback("示例游戏推进 2 分钟，产生新增未保存进度。"); render();
  });
  byId("demo-auto").addEventListener("click", () => {
    write("auto", `自动保存 ${serial}`); render();
  });
  byId("demo-leave").addEventListener("click", () => leaveGate("返回主菜单", () => {
    active = null; feedback("已返回主菜单。继续引用保持最后成功的快照。"); render();
  }));
  byId("demo-new").addEventListener("click", () => leaveGate("创建新世界", () => {
    const world = { id: `world-${serial++}`, name: `测试世界 ${worlds.length + 1}` };
    worlds.push(world); byId("demo-world").add(new Option(world.name, world.id));
    active = { world: world.id, target: null, source: null, tick: 0, dirty: true };
    selected = null; byId("demo-world").value = world.id;
    byId("demo-name").value = "起步"; byId("demo-filter").value = "all"; byId("demo-search").value = "";
    feedback("新世界尚未保存，原继续引用保留。示例临时列出正在运行的世界，第一份成功保存后才持久列出。"); render();
  }));
  byId("demo-delete").addEventListener("click", () => {
    const record = find(selected);
    confirm(`删除 ${worldName(record.world)} / ${record.name}（${types[record.type]}，${record.time}）？${record.backup ? "同时删除其恢复版本。" : ""}`, [
      ["确认删除", () => {
        records = records.filter((entry) => entry.id !== record.id);
        if (active?.target === record.id) active.target = null;
        if (active?.persisted === record.id) active.unprotected = true;
        selected = null; closeConfirm();
        feedback("已删除所选。活动世界保留；如删除继续目标，引用不可用，需另选。"); render();
      }, "danger"],
      ["取消删除", () => { closeConfirm(); feedback("已取消删除，所有记录保持原样。"); }]
    ]);
  });
  byId("demo-rename").addEventListener("click", () => {
    const record = find(selected), name = byId("demo-name").value.trim();
    if (!nameValid(name) || records.some((entry) => entry.id !== record.id && entry.world === record.world &&
        entry.type === "manual" && nameKey(entry.name) === nameKey(name))) {
      feedback("名称无效或同世界已有同名手动档；改名不执行覆盖。", true); return;
    }
    record.name = name;
    feedback("已修改显示名，保存时刻、内容和身份绑定不变。"); render();
  });
  byId("demo-restore").addEventListener("click", () => {
    const record = find(selected), name = byId("demo-name").value.trim();
    if (!nameValid(name) || manualNamed(record.world, name)) {
      byId("demo-name").value = uniqueName(`${record.name}-恢复`, record.world);
      feedback("恢复需不冲突的新名，已预填建议名；确认名称后再次点击恢复为新档。"); return;
    }
    confirm(`将 ${record.name} 的上一成功内容（游戏 ${record.backup.tick} 分钟）恢复为新手动档 ${name}？原档保留，不改变运行现场。`, [
      ["确认恢复为新档", () => {
        if (byId("demo-fail").checked) {
          byId("demo-fail").checked = false;
          feedback("恢复写入失败，原档、恢复版本和现场均保留。", true); return;
        }
        const restored = { ...record.backup, id: `restore-${serial}`, name, sourceTime: record.backup.time,
          time: `示例恢复时刻 ${serial}`, order: serial++ };
        records.push(restored); selected = restored.id;
        closeConfirm(); feedback("已恢复为独立新档，内容时刻来自旧快照；继续引用与手动目标不变，需明确读取。"); render();
      }, "primary"],
      ["取消恢复", () => { closeConfirm(); feedback("已取消恢复。"); }]
    ]);
  });
  byId("demo-reset").addEventListener("click", reset);
  reset();
  if (window.mermaid) {
    const style = getComputedStyle(document.documentElement);
    const color = (name) => style.getPropertyValue(name).trim();
    window.mermaid.initialize({
      startOnLoad: true, securityLevel: "strict", theme: "base",
      fontFamily: style.getPropertyValue("--font").trim(),
      themeVariables: {
        primaryColor: color("--bg"), primaryTextColor: color("--ink"),
        primaryBorderColor: color("--accent"), lineColor: color("--accent"),
        secondaryColor: color("--bg"), tertiaryColor: color("--bg")
      }
    });
  }
})();
