# 用别的语言写 Mod

本项目的 mod 默认用 GDScript（`mod.gd extends ModBase`）。但只要装上下面任意一个
GDExtension，同一个 mod 目录就可以改用对应的语言，**清单、加载顺序、扩展点、
卸载与存档规则完全不变**。

| 运行时 | 入口文件 | 语言 |
|---|---|---|
| （内置） | `mod.gd` | GDScript |
| [Lua GDExtension](https://github.com/gilzoide/lua-gdextension) | `mod.lua` | Lua 5.4 或 LuaJIT |
| [Godot Sandbox](https://github.com/libriscv/godot-sandbox) | `mod.elf` | SafeGDScript / C++ / Rust（编译产物） |

两个扩展**都是可选的**。一个都没装时，工程照常启动、照常通过测试；mod 目录里出现
`mod.lua` / `mod.elf` 只会得到一条明确的安装指引，而不是一个看不懂的解析错误。
判定方式是运行时探测扩展注册的类（`LuaState` / `Sandbox`），**不是**把它们写进
`project.godot`——写进去等于让它们成为硬依赖，缺失时工程会直接加载不起来。

若目录里同时存在多种入口，优先级是：
`mod.gd` → `mod.elf` → `mod.sgd` → `mod.lua`。
所以一个 mod 可以在迁移期间同时带着 GDScript 外壳与 Lua 源码。

---

## 安装

**Lua GDExtension**

1. 从 [Releases](https://github.com/gilzoide/lua-gdextension/releases) 取压缩包
   （Lua 5.4 或 LuaJIT 版），把其中的 `addons/lua-gdextension` 复制到本工程的
   `res://addons/` 下。
2. 在编辑器中打开一次工程，让扩展被导入。
3. `项目设置 → 插件` 里启用它。

**Godot Sandbox**

1. 从 [Releases](https://github.com/libriscv/godot-sandbox/releases) 取压缩包，
   把 `addons/godot_sandbox` 复制到 `res://addons/` 下。
2. 同样在编辑器中打开一次工程。
3. `项目设置 → 插件` 里启用它。

装好后自检：

```powershell
pwsh -File tools\check_runtimes.ps1
# [selftest]   lua_gdextension -> loaded (probe LuaState)
```

启动时也会打印一行状态，三种状态分别是 `loaded` / `installed` / `absent`：

```
[boot] scripting runtimes: godot_sandbox=absent lua_gdextension=loaded
```

`installed`（文件在但类没注册）是最容易困惑的状态：说明扩展没有被导入，
或者缺少当前平台的二进制文件。

---

## 唯一的 API：`game`

外部语言拿到的是一个注册门面，不是 `ModContext`。它**只**提供这些：

### 注册内容

| 方法 | 参数 | 说明 |
|---|---|---|
| `game:add_poi(id, 显示名, 工厂, 权重)` | 工厂返回 `Node3D` | 新地标 |
| `game:add_prop(id, 工厂, 密度, 最大坡度)` | 工厂返回 `Mesh` | 新散布道具 |
| `game:add_item(id, 表)` | 表里至少给 `display_name` | 新物品 |
| `game:add_combat_provider(id, 工厂)` | 工厂返回 `Node`（实现 `Attacker`） | 新战斗实现 |
| `game:add_terrain_modifier(id, 函数, 顺序)` | `函数(x, z, 高度, 海岸遮罩) -> 高度` | 地形改造 |
| `game:add_vehicle(id, 工厂)` | 工厂返回 `Vehicle` | 新载具 |

每个方法返回布尔值：**id 重复会被拒绝**而不是静默覆盖，跟 GDScript 那边一致。

### 订阅

| 方法 | 说明 |
|---|---|
| `game:watch(事件名, 处理函数)` | 订阅核心事件；处理函数按信号原样的参数个数收到位置参数 |
| `game:on(钩子名, 处理函数)` | 挂生命周期钩子 |

可订阅的事件（白名单，未列出的会被拒绝）：`poi_discovered`、`collectible_picked_up`、
`damage_applied`、`attack_started`、`attack_finished`、`combatant_died`、
`player_spawned`、`player_respawned`、`world_ready`、`game_saved`、`game_loaded`、
`notification_posted`、`mod_signal`。

钩子只有五个：`world_generate`、`world_populate`、`player_spawn`、`tick`、`unload`。

### 查询 / 输出

| 方法 | 说明 |
|---|---|
| `game:terrain_height(x, z)` | 地表高度；地形未就绪时返回 `0.0` |
| `game:island_falloff(x, z)` | 岛屿径向遮罩（中心 1、海岸 0） |
| `game:player_position()` | 玩家坐标，无玩家时返回零向量 |
| `game:service_names()` | 本局已注册的服务名 |
| `game:mod_id()` / `game:runtime()` | 自身身份 |
| `game:notify(文本, 级别)` | HUD 通知（级别 0/1/2） |
| `game:log(文本)` | 带 mod id 前缀的日志 |

> 门面里**没有任何**拿到节点、服务或路径的方法。这是刻意的：外部语言 mod 只能
> 注册内容与只读查询，不能随便走进场景树。

---

## Lua 例子

`res://mods/lua_crystals/mod.json`：

```json
{ "id": "lua_crystals", "name": "Lua 水晶", "version": "1.0.0" }
```

`res://mods/lua_crystals/mod.lua`：

```lua
-- 脚本体在加载时执行一次，此时全局 `game` 已经就位。
game:log("lua 水晶：注册中")

-- 一个散布道具。散布系统会自动创建几何与材质，mod 只需要返回一个 Mesh。
game:add_prop("lua_crystal", function()
    local sphere = SphereMesh.new()
    sphere.radius = 1.3
    sphere.height = 2.6
    return sphere
end, 0.7, 38.0)

game:add_item("lua_shard", { display_name = "水晶碎片", stackable = true })

-- 事件与钩子。参数按位置传入，跟 GDScript 侧重写时拿到的一样。
game:watch("poi_discovered", function(poi_id, display_name, position)
    game:notify("发现 " .. display_name, 1)
end)

game:on("world_populate", function(world)
    local h = game:terrain_height(0, 0)
    game:log(string.format("世界已就绪，中心高度 %.1f m", h))
end)
```

也可以用显式的 `on_register` 代替顶层语句：

```lua
function on_register(game)
    game:log("显式入口")
end
```

> 顶层语句与 `on_register` 都存在时，**两者都会执行**（脚本体先，`on_register` 后）。

---

## SafeGDScript / 沙盒程序

Godot Sandbox 运行的是**编译产物**，不是源码：`.sgd` / C++ / Rust 都要先用它的
工具链编译成 ELF，再把产物命名为 `mod.elf` 放进 mod 目录。只放 `mod.sgd` 会被
明确告知去编译，而不是被悄悄忽略。

沙盒程序必须导出一个入口 `on_register(game)`：

```gdscript
# 编译前：SafeGDScript 源码。编译产物请命名为 mod.elf 放进 mod 目录。
var total_registered := 0

func add_tower(game) -> void:
    game.add_poi("sgd_tower", "沙盒塔", func() -> Node3D:
        var root := Node3D.new()
        var mesh := MeshInstance3D.new()
        var box := BoxMesh.new()
        box.size = Vector3(3.0, 12.0, 3.0)
        mesh.mesh = box
        mesh.position = Vector3(0.0, 6.0, 0.0)
        root.add_child(mesh)
        return root
    , 1.0)
    total_registered += 1

func on_register(game) -> void:
    add_tower(game)
    game.on("world_populate", func(_world) -> void:
        game.notify("沙盒 mod 已注入 %d 项" % total_registered, 1)
    )
```

`mod.elf` 的目录结构与其他 mod 完全一样：

```
res://mods/sgd_tower/
    mod.json
    mod.elf     # 编译产物
```

---

## 失败与诊断

外部语言 mod 的失败走的是与 GDScript mod 相同的通道：

- 引擎日志里有 `[ModHost] <id>: <原因>`；
- `Events.mod_failed` 会发出，`Esc` 菜单的 mod 列表会显示失败原因；
- 启动失败（未装运行时、源码没编译、Lua 报错）的 mod **不会被加载**，
  它的注册也会被整体撤回，其余 mod 不受影响。

**注意 `/ --script` 模式的限制**：Godot 不会把 autoload 标识符注册进
`--script` 入口的编译作用域，而 `script_bridge.gd` 正常引用了 `Services` 与
`Events`，所以在 `--script` 下它会编译失败。兼容层自检因此做成一个场景
（`tools/runtime_self_test.tscn`），由 `tools/check_runtimes.ps1` 运行。

---

## 安全

沙盒的意义是"别人给的东西可以放心试"。本项目在这件事上的立场：

- 外部语言 mod 只能通过 `game` 门面注册内容与做只读查询，拿不到场景树。
- 事件订阅是白名单，不能按字符串订阅任意信号。
- `body:add_*` 的 id 冲突会被拒绝，跟 GDScript mod 同规则。
- 但**默认的 Lua 库集合未做裁剪**：`open_libraries()` 按扩展的默认值打开，
  可能包含 `io` / `os`。需要严格限制的宿主应当在
  `src/core/scripted_mod.gd` 的 `_start_lua()` 里传入明确的库子集
  （需要装了扩展才能引用它的枚举，因此这里没有替使用者猜）。
- Godot Sandbox 侧的安全性由扩展本身（RISC-V 机器码沙盒 + 主机显式授权）提供。
