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

启动时 `ModLoader` 会依次调用：`_on_register` → （世界生成后）`_on_world_generate`
→ （内容放置后）`_on_world_populate` → （玩家生成后）`_on_player_spawn`，每帧
`_on_tick`，卸载时逆序 `_on_unload`。

> 钩子必须是同步的，且只会在主线程调用。运行期异常会打印到日志并中断该 mod 的
> 当次调用；写 mod 时请自行判断前置条件（例如 `Services.get_as` 可能返回 `null`）。

---

## 扩展点（`context`）

`mod.gd` 里通过 `context` 注册内容。所有注册都会检查 id 冲突：重名会警告并保留
先注册者，不会静默覆盖别人的内容。

### 1. 新地标

```gdscript
func _on_register() -> void:
    context.add_poi_factory(&"my_tower", "我的塔", _make_tower, 1.0)  # 权重

func _make_tower() -> Node3D:
    var root := Node3D.new()
    var mesh := MeshInstance3D.new()
    var cylinder := CylinderMesh.new()
    cylinder.height = 8.0
    mesh.mesh = cylinder
    mesh.position = Vector3(0.0, 4.0, 0.0)
    mesh.material_override = PoiMarker.standard_material(Color(0.6, 0.6, 0.65))
    root.add_child(mesh)
    return root
```

发现逻辑由核心的 `PoiMarker` 负责：玩家进入半径即记录一次（只记一次），发出
`Events.poi_discovered`，并在已发现时不再重复触发。

### 2. 新散布道具

工厂返回**一个** `Mesh`，实例化由散布系统负责（`MultiMesh`），所以不要自己摆几千个节点。

```gdscript
func _on_register() -> void:
    context.add_prop_factory(&"my_stone", _make_stone, 0.8, 35.0)  # 密度 / 最大坡度

func _make_stone() -> Mesh:
    var primitive := SphereMesh.new()
    primitive.radius = 0.8
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, primitive.surface_get_arrays(0))
    return PropFactory.paint(mesh, 1.0, 0.6)   # 顶点色：G=混色，R=明暗
```

### 3. 新物品

```gdscript
context.add_item_definition(&"my_relic", {
    "display_name": "遗物",
    "description": "…",
    "stackable": false,
})
```

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

### 5. 地形改造

```gdscript
func _on_register() -> void:
    context.add_terrain_modifier(&"my_plateau", _raise, 40)   # 数字越小越先执行

func _raise(x: float, z: float, height: float, falloff: float) -> float:
    var d := Vector2(x, z).distance_to(Vector2(100.0, -50.0))
    if d >= 40.0:
        return height
    return height + pow(1.0 - d / 40.0, 2.0) * 8.0 * falloff
```

`falloff` 是岛屿径向遮罩（中心 1、海岸 0），乘上它可以让改动随海岸自然消失。
同 `order` 的修改器按 id 排序，保证确定性。

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

## 可直接使用的公共服务

| 服务 | 获取方式 | 用途 |
|---|---|---|
| `terrain_query` | `Services.get_as(&"terrain_query", &"TerrainQuery")` | 地表高度、法线、坡度、岛屿遮罩 |
| `world_builder` | `Services.get_service(&"world_builder")` | 重新构建世界、寻找出生点 |
| 事件 | `Events.<信号>` | 见 `src/core/event_bus.gd` 全部契约 |
| 存档 | `SaveSystem` | 存读档、槽位枚举 |

`TerrainQuery` 常用方法：`height_at(x, z)`、`sample_height(pos, clearance)`、
`slope_degrees_at(x, z)`、`is_placeable(x, z, max_slope)`、`island_falloff(x, z)`。

---

## 调试

- `F1` 打开调试浮层：帧率、种子、坐标、速度、体力、服务列表、已加载 mod、地表高度范围。
- `Esc` 菜单里有 mod 列表（含加载失败原因）。
- 无头验证：

```powershell
pwsh -File tools\check_scripts.ps1      # 语法
pwsh -File tools\smoke_test.ps1         # 启动 + 碰撞 + mod 加载
pwsh -File tools\smoke_test.ps1 -Validate   # 只跑启动并打印世界统计
```
