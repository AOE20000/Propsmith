# 编写 Mod

一个 mod 就是一个目录，放在 `res://mods/<名字>/` 下：

```
res://mods/my_mod/
    mod.json     # 可选清单
    mod.gd       # 必需入口，extends ModBase
```

`mod.json` 全部字段可选（缺省用目录名）：

```json
{
  "id": "my_mod",
  "name": "我的 Mod",
  "version": "1.0.0",
  "author": "you",
  "enabled": true,
  "dependencies": ["lighthouse"]
}
```

加载顺序按 `dependencies` 拓扑排序，同层按 id 排序，所以**同样的一批 mod 每次加载
顺序一致**。声明了不存在的依赖只会警告，不会阻止启动。

启动时 `ModHost` 会依次调用：`_on_register` → （世界生成后）`_on_world_generate`
→ （内容放置后）`_on_world_populate` → （玩家生成后）`_on_player_spawn`，每帧
`_on_tick`，卸载时逆序 `_on_unload`。

> 钩子必须是同步的，且只会在主线程调用。运行期异常会打印到日志并中断该 mod 的
> 当次调用；写 mod 时请自行判断前置条件（例如 `Services.get_as` 可能返回 `null`）。

---

## 扩展点（`context`）

`mod.gd` 里通过 `context` 注册内容。所有注册都会检查 id 冲突：重名会警告并保留
先注册者，不会静默覆盖别人的内容。

### id 冲突规则（同 mod 内与跨 mod）

- **同一个 mod 内**重名：拒绝，并警告"保留先注册者"。
- **不同 mod 之间**重名：同样**保留先加载者**（加载顺序由依赖拓扑排序决定，因此是确定的），
  并把冲突记到**后注册的那个 mod** 的失败说明里，`Esc` 菜单的 mod 列表能直接看到。
  没有这条检查时，后来者的内容会静默消失，作者无从下手。

工厂类扩展点（poi / prop / combat / terrain / vehicle / **tool** / **npc**）在注册时
就要求传入**有效的 `Callable`**（或 `SandboxTool` 实例），物品要求 `display_name`——
不合格的注册当场被拒，而不是等到世界生成时在一个跟错误原因毫无关系的地方炸掉。

> **扩展点现状（P3 起）**：`add_prop_factory`（**真消费者**：生成菜单实例化它，
> 工厂返回 RigidBody3D）、`add_npc_factory`（**真消费者**：生成菜单的 NPC 区，
> 工厂返回 CharacterBody3D）、`add_tool_callbacks` / `add_tool`（**真消费者**：
> 工具枪轮盘与建造面板）、`add_player_model`（**真消费者**：替换默认玩家形象）。
> `add_poi_factory` 与 `add_terrain_modifier` 仍是预留（旧地形系统的消费者已移除），
> `add_item_definition` 也仍预留（无库存系统）——注册都安全，只是无可见效果。
> 在地图上放内容也可以用 `_on_world_populate` 直接注入——见 `mods/lighthouse/`。

### 1. 往世界里放自己的东西（推荐入口）

地图就绪后，核心会调用 mod 的 `_on_world_populate(world)`。这是城市地图上最直接的
内容注入点：自己建节点、自己定位、自己加进去。

```gdscript
func _on_world_populate(world: Node3D) -> void:
    var query: SurfaceQuery = Services.get_as(&"surface_query", &"SurfaceQuery") as SurfaceQuery
    if query == null or not query.is_ready():
        return
    var tower := _make_tower()
    tower.position = query.sample_height(Vector3(0.0, 0.0, 0.0), 0.0)
    world.add_child(tower)
```

地表查询服务 `surface_query` 用物理射线回答"这儿的地面在哪"：`height_at(x, z)`、
`sample_height(pos, clearance)`、`slope_degrees_at(x, z)`、`is_placeable(x, z, max_slope)`、
`surface_kind(x, z)`（`ground` / `building` / `none`）。完整例子见 `mods/lighthouse/`。

### 2. 注册可生成道具（真消费者：生成菜单）

```gdscript
func _on_register() -> void:
    # 工厂返回一个配置好的 RigidBody3D（网格 + 碰撞 + 质量）
    context.add_prop_factory(&"my_crate", "我的箱子", _make_crate, "basic")
```

生成菜单的"basic"分类下会出现"我的箱子"；点击即按准星落点生成。

### 3. 注册 NPC（真消费者：生成菜单 NPC 区）

```gdscript
func _on_register() -> void:
    # 工厂返回 CharacterBody3D——通常是换皮的 PedestrianAgent：
    # 日程行走、无地点表时游荡、可被伤害致死，全部自带
    context.add_npc_factory(&"my_guard", "我的卫兵", _make_guard)
```

### 4. 注册工具（真消费者：工具枪 + 建造面板）

回调式（最简单，Lua mod 同款形状）：

```gdscript
func _on_register() -> void:
    context.add_tool_callbacks(&"my_mark", "我的标记", {
        "on_primary": func(hit: Dictionary) -> void:
            Events.notify("点击了 %s" % str(hit.get("collider"))),
        "on_secondary": func(_hit: Dictionary) -> void: pass,
    })
```

全控式（继承 `SandboxTool`，状态机自己写）：`context.add_tool(my_tool_instance)`。
键 3 切到工具枪后，滚轮或建造面板选择工具。

### 5. 替换默认玩家模型（真消费者：玩家出生形象）

```gdscript
func _on_register() -> void:
    # 工厂返回 Node3D——模型根：脚在原点、面向 +Z（玩家会转到 -Z）。
    # 多个 mod 注册时按 id 序取第一个；外观面板/存档继续工作，
    # 换装/配色/体形按网格与骨骼名匹配，模型缺的项静默跳过。
    context.add_player_model(&"my_hero", "我的主角",
        func() -> Node3D: return (load("res://mods/my_hero/hero.glb") as PackedScene).instantiate())
```

Lua mod 同款：`bridge.add_player_model("my_hero", "我的主角", factory)`。

### 6. 新物品（预留，核心尚未消费）

```gdscript
context.add_item_definition(&"my_relic", {
    "display_name": "遗物",
    "description": "…",
    "stackable": false,
})
```

> **当前状态：预留扩展点。** 注册与校验都已实现，采集的词汇也已经铺好
> （`Events.collectible_picked_up`、`GameState.mark_collected`），但**核心还没有任何
> 模块读取 `item_definitions`**——没有库存、没有掉落物、没有拾取交互。
> 注册是安全的，只是不会产生可见效果；`display_name` 现在是必填，因为任何将来的
> 消费者第一件事都是把它显示出来。这条边界同时写在 README 的「已知边界」里。

### 4. 新战斗实现

战斗只有接口，所以"实现一个武器"就是实现 `Attacker`：

```gdscript
context.add_combat_provider(&"my_weapon", func() -> Node:
    var weapon := BasicMeleeWeapon.new()
    var attack := AttackData.new()
    attack.attack_id = &"my_weapon"
    attack.damage = 26.0
    attack.cooldown = 0.9
    weapon.attack = attack
    return weapon
)
```

要让玩家用上它，把玩家场景里 `AttackController.attacker_path` 指向该节点，或直接
替换 `melee_basic` 提供者。也可以完全不用 `BasicMeleeWeapon`，只要节点实现
`Attacker`（`try_attack` / `is_attacking` / `cancel_attack`）与 `Damageable`
（`can_receive_damage` / `apply_damage` / `health_fraction` / `is_defeated`）。

### 5. 地形改造（预留，城市地图暂无消费者）

```gdscript
func _on_register() -> void:
    context.add_terrain_modifier(&"my_plateau", _raise, 40)   # 数字越小越先执行

func _raise(x: float, z: float, height: float, falloff: float) -> float:
    var d := Vector2(x, z).distance_to(Vector2(100.0, -50.0))
    if d >= 40.0:
        return height
    return height + pow(1.0 - d / 40.0, 2.0) * 8.0 * falloff
```

`falloff` 参数沿自旧地形系统（当时是径向遮罩），当前签名保持不变以稳定 mod API。
注册排序规则（同 `order` 按 id）仍然有断言钉住，只是当前地图上没有高度场可以改。

### 6. 事件与自有信号

监听核心事件：

```gdscript
func _on_register() -> void:
    Events.poi_discovered.connect(_on_poi)
    Events.damage_applied.connect(_on_damage)
    Events.collectible_picked_up.connect(_on_pickup)
```

mod 之间通过 `Events.mod_signal` 通信（第一参数是发出者的 mod id）：

```gdscript
emit_mod_signal(&"boss_defeated", {"id": "shadow"})
```

### 7. 自己存档

```gdscript
func serialize() -> Dictionary:
    return {"score": _score}          # 任意 JSON 安全数据

func deserialize(data: Dictionary) -> void:
    _score = int(data.get("score", 0))
```

数据存在 `sections["<你的 mod id>"]` 下，核心存档格式无需改动。返回空字典表示
本次不写任何数据。

---

## 扩展点：载具

`add_vehicle_factory` 让 mod 增加一种可驾驶载具。工厂必须返回一个 `Vehicle`
（而不是裸的 `VehicleBody3D`）——只有 `Vehicle` 带座位交互和乘客吸附，
返回裸载具会被拒绝并说明原因，这比"能开但上不去"更好排查。

载具由 `VehicleSystem` 在玩家出生点附近挑一块平地停放；同一次启动里
每个工厂各放一辆，顺序按 id 排定，所以两次运行位置一致。

```gdscript
func _on_register() -> void:
    context.add_vehicle_factory(&"my_buggy", _make_buggy)

func _make_buggy() -> Vehicle:
    # 复用工程自带的构建器，只改参数；这样默认载具以后加的新特性你会自动继承。
    var vehicle: Vehicle = VehicleScene.build("Vehicle_my_buggy")
    vehicle.mass = 720.0
    vehicle.max_engine_force = 2600.0
    vehicle.max_speed = 34.0
    return vehicle
```

要一辆**外形完全不同**的载具就自己在工厂里组装：放一个 `CollisionShape3D`、
若干 `VehicleWheel3D`（前轮 `use_as_steering`，后轮 `use_as_traction`）、
一个名为 `Seat` 的 `VehicleSeat`、一个名为 `ExitPoint` 的 `Marker3D` 即可。
`Vehicle._ready()` 靠这些节点名接线，不靠顺序。

完整例子见 `mods/garage/`。

### 上下车是怎么接到核心的

座位就是一个普通的 `Interactable`，因此玩家已有的探测、提示与 `E` 键链路
直接复用，核心三处都没为载具改过一行。`Player.take_control()` 挂起自身的移动/重力并关掉碰撞体，位置由座位每物理帧写入。
下车反向走 `release_external_control()`，并把乘客放到地表查询出的地面上（而不是车厢里）。

---

## 用别的语言写 mod

`mod.lua`（Lua GDExtension）与 `mod.sgd` / `mod.elf`（Godot Sandbox）是
`mod.gd` 之外的合法入口。二者的清单、加载顺序、扩展点与 GDScript mod 完全一致，
差别只在 `context` 换成了 `game` 这个门面。见
[SCRIPTED_MODS.md](SCRIPTED_MODS.md)。

> 与本项目无关的另一种 mod：`godot-mod-loader`（`addons/mod_loader/`）。
> 它认的是 `manifest.json` 与 `.zip`，用来在不接触游戏源码的前提下改写脚本与资源，
> 属于另一条路线。两套加载器靠清单文件名分工，互不干扰。

### autoload 顺序是硬约束（理由写在这里，不写在 project.godot）

```
ModLoaderStore, ModLoader,    # godot-mod-loader 要求自己占前两位
Services, Events, GameState, ModHost, SaveSystem
```

- `godot-mod-loader` 启动时会断言自己位于前两位，位置不对就报错。两个 autoload 的名字
  也只能是这两个——它的代码里有上百处直接引用 `ModLoaderStore.`。
- 本项目自己的五个 autoload **相对顺序不能动**：`ModHost` 在 `_ready()` 里向 `SaveSystem`
  注册存档段，而 `SaveSystem` 声明在它之后——这是改名之前就如此的历史顺序。
- ⚠️ **不要在 `project.godot` 里写解释性注释**：Godot 重写该文件时会丢掉用户注释，
  只保留它自己生成的文件头。这条理由曾经写在 `[autoload]` 段里，在装好加载器、工程被
  Godot 重新保存一次之后就消失了（autoload 条目本身没丢）。所以文档放在这里。

---

## 可直接使用的公共服务

| 服务 | 获取方式 | 用途 |
|---|---|---|
| `surface_query` | `Services.get_as(&"surface_query", &"SurfaceQuery")` | 地表高度、坡度、表面类型（物理射线，只打地图层） |
| `map_source` | `Services.get_service(&"map_source")` | 当前地图源：出生点、地图身份、加载统计 |
| 事件 | `Events.<信号>` | 见 `src/core/event_bus.gd` 全部契约 |
| 存档 | `SaveSystem` | 存读档、槽位枚举、**读档校验地图身份** |

---

## 调试

- `F1` 打开调试浮层：帧率、地图身份、坐标、速度、体力、服务列表、已加载 mod、脚下地表。
- `Esc` 菜单里有 mod 列表（含加载失败原因）。
- 无头验证：

```powershell
pwsh -File tools\check_scripts.ps1      # 语法
pwsh -File tools\smoke_test.ps1         # 启动 + 碰撞 + mod 加载
pwsh -File tools\smoke_test.ps1 -Validate   # 只跑启动并打印世界统计
pwsh -File tools\check_runtimes.ps1     # 可选脚本运行时兼容层自检
```
