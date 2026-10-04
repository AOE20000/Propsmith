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

工厂类扩展点（poi / prop / combat / terrain / vehicle / **tool** / **npc** /
**render style**）在注册时就要求传入**有效的 `Callable`**（或 `SandboxTool` 实例），
物品要求 `display_name`——不合格的注册当场被拒，而不是等到世界生成时在一个跟错误原因
毫无关系的地方炸掉。

> **扩展点现状（P3 起）**：`add_prop_factory`（**真消费者**：生成菜单实例化它，
> 工厂返回 RigidBody3D）、`add_npc_factory`（**真消费者**：生成菜单的 NPC 区，
> 工厂返回 CharacterBody3D）、`add_tool_callbacks` / `add_tool`（**真消费者**：
> 工具枪轮盘与建造面板）、`add_player_model`（**真消费者**：替换默认玩家形象）、
> `add_render_style` / `add_render_style_preset`（**真消费者**：画风切换，`F2`）、
> `add_map_source`（**真消费者**：`MapCatalog` 解析会话的地图，`DSH_MAP_SOURCE` 选）。
> `add_poi_factory` 与 `add_terrain_modifier` 仍是预留（旧地形系统的消费者已移除），
> `add_item_definition` 也仍预留（无库存系统）——注册都安全，只是无可见效果。
> 在地图上放内容也可以用 `_on_world_populate` 直接注入——见 `mods/lighthouse/`。

## 扩展点：整张地图

`context.add_map_source(source, selector_id, display_name)` 注册一张**完整的地图**
——不是放在地图里的内容，而是"这一局发生在哪里"。核心只自带 Demo 地图；涩谷
（需要 `godot-plateau` 扩展与不入库的数据集）就是这么提供的，见
`mods/plateau_city/`。

两个 id 别混：

- **`selector_id`**：`DSH_MAP_SOURCE` 与菜单用的**稳定名字**（如 `shibuya`）。
- **`source.map_id()`**：**存档指纹**——涩谷的是数据集文件的哈希，数据一重导出就变。
  目录按选择器取键，指纹留在地图源里给存档校验用。

请求了一个目录里没有的地图时，启动会**说明有哪些可选**再回落到 Demo——静默换图
等于让玩家盯着错误的世界却没人解释。数据式 Mod（只带 JSON、不带代码）**无法**
注册地图：一张地图就是一个 `MapSource` 子类，这需要代码，属于能力边界而非缺陷。

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

### 7. 新战斗实现

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

### 8. 地形改造（预留，城市地图暂无消费者）

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

### 9. 事件与自有信号

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

### 10. 自己存档

```gdscript
func serialize() -> Dictionary:
    return {"score": _score}          # 任意 JSON 安全数据

func deserialize(data: Dictionary) -> void:
    _score = int(data.get("score", 0))
```

数据存在 `sections["<你的 mod id>"]` 下，核心存档格式无需改动。返回空字典表示
本次不写任何数据。

### 11. 换一种画风（真消费者：画风切换，`F2`）

渲染也是可注册的玩法面。画风（render style）决定**画面怎么被画出来**——环境、屏幕
空间通道、渲染设置——但**绝不碰世界状态**。游戏自带 `写实` 与 `3渲2` 两种，`F2` 循环
切换；你注册的画风会和它们并列出现在同一个循环里。

**最低成本的一种：只给一张覆盖表。** 键就是 `DemoLook` 的预设键（`src/world/demo_look.gd`
里的预设表就是全部可用键）。

```gdscript
func _on_register() -> void:
    display_name = "我的画风"
    context.add_render_style_preset(&"golden_hour", "黄金时刻", {
        "sun_angle": Vector3(-16.0, -62.0, 0.0),
        "sun_color": Color(1.0, 0.80, 0.52),
        "sky_horizon": Color(0.98, 0.72, 0.42),
        "fog_color": Color(0.92, 0.70, 0.50),
        "saturation": 1.18,
    })
```

三条约定，理解它们就不会写出"切换后画面回不去"的画风：

1. **画风是"覆盖"，不是"拥有"。** 它在地图自己写好的气氛之上重调一遍
   （`DemoLook.apply_to`：预设 + 覆盖，一次调用写回全部键）。所以覆盖表里**没写的键
   自动回到地图预设的值**——这就是"切回去"能成立的原因，不需要你保存/还原任何东西。
2. **不要假设是哪张地图、哪个预设。** 想知道当前预设用 `DemoLook.preset_of(env)`；
   想知道这张地图的调色板用 `DemoLook.preset(...)`（`3渲2` 的手绘天空就是这么拿到
   地图自己那两种天空色的——风格换的是**处理**，不是**调色板**）。
3. **`apply()` 与 `release()` 成对。** `apply()` 返回 false 表示这次应用失败，调度器
   会退回 `写实`；`release()` 必须能把 `apply()` 加进场景的东西收干净。

**要自带着色器/通道时**，写一个 `RenderStyle` 子类：

```gdscript
class NoirStyle extends RenderStyle:
    const POST_SHADER: Shader = preload("res://mods/我的mod/noir.gdshader")

    func style_id() -> StringName: return &"noir"
    func display_name() -> String: return "黑白电影"

    func apply(context: Dictionary) -> bool:
        if not retune(context, {"saturation": 0.0, "glow_enabled": false}):
            return false
        return attach_screen_pass(context, POST_SHADER, "NoirPost") != null

    func release() -> void:
        release_screen_pass()
```

> ⚠️ **通道着色器必须是 `shader_type spatial`。** 全屏通道画在一个由 `ScreenPass` 每帧
> 挪到**当前相机**前面的四边形上，不画在 `CanvasLayer` 上——因为 `canvas_item` 着色器
> 读不到深度缓冲（`hint_depth_texture` 不支持），而墨线要靠深度。
> 也因此：**换相机（自由视角、载具座位）通道不会掉**。
> 需要"一个屏幕像素"的 UV 时声明 `uniform vec2 screen_pixel_size;`，由 `ScreenPass`
> 每帧推给你（`SCREEN_PIXEL_SIZE` 是 canvas 着色器的内建，spatial 里没有）。

**能力边界（诚实说明）**：

- 3D 材质能读到的 `hint_screen_texture` 是**不透明阶段**的拷贝——透明物体之间互相看不见。
  所以"整帧替换"式的后处理会把水、以及任何透明面**抹掉**；正确做法是**叠加**（像内置的
  `3渲2` 那样：输出覆盖色 + alpha，让场景保留自己的颜色）。真要在最终合成之后处理，
  需要 Godot 4.3+ 的 `CompositorEffect`，那是另一条路。
- **屏幕空间分色阶天生会有"等高线"**：一大片平坦表面上，只要它的明度刚好落在某个色阶
  边界附近，那条边界就会被画在表面上——形状取决于该表面明度的微弱漂移（内置 `3渲2`
  的一堵墙就出现过两道弧，用调试色块定位确认过是墙自身的渐变）。抖动只能柔化边界、
  去不掉它（平均值仍然跳变）。**真正的解法是按材质给光照分色阶**（`MToon` 对角色就是
  这么做的，见 `addons/Godot-MToon-Shader`），让色阶边界落在明暗交界、褶皱这些有意义的
  位置，而不是落在算法算到的地方——那是这个画风的下一步，屏幕空间通道做不到。

可直接抄的例子见 `mods/render_style_demo/`（`黄金时刻` 走纯数据，`黑白电影` 自带着色器）。

---

## 决策日志：让 mod 的改动自动持久化与联机

mod 对世界做出的**离散变更**（放置/移除/改状态）可以通过决策日志记录。好处：

- **崩溃安全**：每条决定立即追加到日志，进程被杀也不丢失已发生的变更；
- **联机免费**：联机会话中，决定自动广播给所有玩家——**mod 作者不需要写任何
  网络代码**；
- **加载即重放**：读档 = 快照（各 mod 的 `serialize` 节）+ 日志尾重放（调用你
  注册的 applier）。

```gdscript
func _on_register() -> void:
    # 声明决定 kind 与重放器。kind 会自动加 mod id 前缀，不会与别的 mod 冲突。
    context.register_decision_applier(&"place_shrine", _apply_shrine)

func _apply_shrine(payload: Dictionary) -> void:
    # 重放与远端同步都会调用这里：按 payload 原样重建状态，
    # 与"玩家刚刚实时做出这个改动"时走完全相同的代码。
    var shrine := _make_shrine(String(payload.get("name", "")))
    shrine.position = payload.get("position")
    add_child(shrine)

func _on_shrine_placed(name: String, position: Vector3) -> void:
    # 玩家做出改动：先在本地应用，再把决定交给日志。
    var shrine := _make_shrine(name)
    shrine.position = position
    add_child(shrine)
    context.record_decision(&"place_shrine", {"name": name, "position": position})
```

约定（违反会让重放出错）：

- **payload 必须自足**：包含重建状态所需的全部数据，不引用发出时刻的临时状态。
- **applier 与实时路径共用同一份重建代码**：不要为"读档"另写一份逻辑。
- 长期持久化仍走你自己的 `serialize` / `deserialize` 钩子——决策日志是
  广播与崩溃恢复通道，不是第二份存档文件。

Lua / SafeGDScript 同款：`game:record_decision(kind, payload)` 与
`game:register_decision_applier(kind, handler)`。

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
Services, Events, DecisionLog, GameState, ModHost, SaveSystem
```

- `godot-mod-loader` 启动时会断言自己位于前两位，位置不对就报错。两个 autoload 的名字
  也只能是这两个——它的代码里有上百处直接引用 `ModLoaderStore.`。
- 本项目自己的 autoload **相对顺序不能动**：`DecisionLog` 需要在 `Events` 之后
  （订阅其存档信号）、`ModHost` 在 `SaveSystem` 之前（向其注册存档段）。
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
| 决策日志 | `DecisionLog.record / register_applier` | 世界变更的持久化与联机广播（建议走 `context` 的包装） |

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
