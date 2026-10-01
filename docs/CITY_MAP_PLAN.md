# 开发计划：PLATEAU 作为默认地图 + 标签驱动的城市人类移动

> 状态：**设计阶段**（地图层未实现）。移动核心**已实现并通过断言**（`src/mobility/`）。
>
> ## 本次变更（取代上一版荷兰方案）
>
> - 地图改用 **PLATEAU**（日本国土交通省 MLIT 的全国 3D 都市模型）+ **PLATEAU SDK for Godot**。
> - **放弃荷兰地图**（3D BAG / AHN / BGT / BAG 全部退出）与**全部真实轨迹/移动数据**
>   （NDW / ODiN / GTFS 退出）。移动改成**纯标签驱动**。
> - 已确认的四项决策不变：可交互个体 · 街区优先（架构预留流式）· 城市地图不依赖 Terrain3D ·
>   **移动层与数据源解耦**。
>
> **为什么这次切换很便宜**：上一轮把移动层做成了"只认规范活动标签"，它从来没用过任何
> 轨迹数据。而 PLATEAU 的建筑自带 **`bldg:usage`（用途）**语义——**真实 3D 城市模型直接就能
> 供给标签**。所以"放弃轨迹"实际上是**免费**的：换掉的只是地图来源，行为层一行未改，
> 新增的只是日语词表（已加，13 条断言钉住）。

---

## 1. 目标与非目标

### 目标
- 用 **PLATEAU** 开放数据构建可步行、可驾驶的**真实城市街区**，作为默认地图。
- 城市里的行人/车辆是**可交互个体**：有行程目的（家→工作→消费→回家），能跟踪、搭载、阻挡。
- 行为由**地图自身的语义**驱动：PLATEAU 的 `bldg:usage` → 规范活动标签 → 活动模式 → 具体路线。
- 与现有架构一致：城市作为**一个 `MapSource`** 接入；四件套保持全绿。

### 非目标
- **不使用任何真实轨迹数据**。街区的"人流"是**生成**的，不声称与真实客流吻合。
  没有校准数据集 → 也就**没有"与实测流量相关性"这类验收指标**（荷兰方案里那一条随之取消）。
- 第一期不做全城可走（街区优先）；不做建筑内部；不做信号灯级微观交通仿真。
- 不把 PLATEAU 数据提交进 git 仓库（体积 + 多许可，见 §3）。

---

## 2. 地图来源：PLATEAU

### 2.1 数据（可获取、可商用）

| 项 | 事实 |
|---|---|
| 提供方 | 日本国土交通省 **MLIT**，Project PLATEAU |
| 获取 | **G 空間情報センター**（`geospatial.jp/ckan/dataset/plateau`）；**无需手续** |
| 许可 | **CC BY 4.0 / 政府標準利用規約 / ODbL / ODC-BY 多许可**，**允许商用**，**要求署名** |
| 覆盖 | **约 250+ 个日本城市** |
| 格式 | 标准格式 **CityGML**；另有 3D Tiles / GeoJSON / MVT / GeoTIFF；部分城市另提供 OBJ/FBX |
| CRS | **EPSG:6697**（JGD2011 三维复合：水平为经纬度、垂直为米） |
| 地物 | 共 **20 类**。基本数据集：**建筑（LOD0–2）**、交通（道路）LOD1、都市計画決定情報、土地利用、災害リスク、**地形** LOD1；另有都市設備、植生、水部、橋梁、トンネル、地下街等 |
| 建筑属性 | **`bldg:usage`（用途）**、`bldg:measuredHeight`（高度）、`bldg:storeysAboveGround`（地上层数）、屋顶类型；**每个面**也可带属性（屋顶/地板/内墙/外墙） |
| 纹理 | 规格基本为 **10 cm/pixel** —— 俯瞰清晰，**平视近距离会显粗糙** |

**默认城市建议：渋谷区（东京）**。它是 PLATEAU 演示最充分、LOD2 + 纹理覆盖最好的区域之一，
且街区尺度合适。**城市选择现在几乎零成本**——管线按自治体下载，换城市只改一处配置。

### 2.2 SDK 现状（这是本计划最大的不确定性）

| 项 | 事实 |
|---|---|
| 项目 | **[`shiena/godot-plateau`](https://github.com/shiena/godot-plateau)** — GDExtension |
| 性质 | **非官方社区项目**（未获 MLIT / Godot Foundation 认可；PLATEAU **没有官方 Godot SDK**，官方只有 Unity / Unreal） |
| SDK 许可 | **MIT**（内含的 `libplateau` 自带许可，需一并记录） |
| 声称版本 | **Godot 4.5**；最新 **v1.0.1**，约 7 个月前发布 |
| 能力 | 加载 CityGML 生成网格 · **LOD 选择与自动切换** · **地理↔局部坐标转换** · PBR 材质与纹理 · **属性访问（GML ID、CityObjectType）** · 编辑器导入对话框 · 导出 glTF/GLB/OBJ · Windows/macOS/Linux/Android/iOS |
| 源码结构里可见的类 | `CityModel` / `MeshData` / `GeoReference` / `Importer` / `MeshExtractOptions` / `GmlFile` / `InstancedCityModel` / `CityModelScene`+`FilterCondition` / `CityObjectType` / **`DynamicTile`（动态瓦片加载）** / **`RoadNetwork`（路网数据）** / `Terrain` / `HeightMapData` / `HeightMapAligner` / `VectorTile*` |
| 已知限制 | **OBJ 导出每个建筑一个 group** → 建筑多时会撞 Godot 的单网格 **256 面上限**（用 AREA 粒度合并规避）；**移动平台**缺少地形/高度图/矢量瓦片相关类（桌面不受影响） |

> ⚠️ **头号风险**：SDK 声称支持 **Godot 4.5**，而本工程是 **4.7.2**，且该版本已发布约 7 个月。
> GDExtension 在同 4.x 内通常向前兼容，但**必须实测**（见 M0）。
>
> **备选路线（若 SDK 不可用）**：走 Blender 作为转换桥（CityGML → 优化 → glTF）。
> 这条路线有公开记录，也记录了两个必须预期的坑：**法线翻转**、**共面 Z-fighting 与网格碎片**，
> 以及"CityGML 是给人看的、不是给物理引擎用的"——**碰撞体要自己生成**。
> 无论走哪条路线，**SDK 都当可选依赖**：沿用工程既有的 `ClassDB` 探测 + 优雅降级，
> **绝不写进 `project.godot`**（写进去它就成了硬依赖）。

### 2.3 移动数据：不需要（这是解耦的收益）

原方案用 ODiN 出行率、NDW 路段流量、GTFS 班次来"喂"移动层。现在这三者**全部退出**：
PLATEAU 的建筑用途已经给出**活动地点**，而"人一天怎么走"由**活动模式**表达。

| 原来源 | 现在 | 说明 |
|---|---|---|
| ODiN 出行率 | 不需要 | 出行率由 `ActivityPattern` 与每个体的种子决定 |
| NDW 路段流量 | 不需要 | 没有校准目标，**校准验收指标一并取消**（诚实：不再声称与实测吻合） |
| GTFS 班次 | 不需要 | 公交是后续可选玩法，不是移动层的前提 |
| 3D BAG / BAG / BGT | **由 PLATEAU 取代** | 建筑 + `bldg:usage` + 道路（交通 LOD1 / SDK 的 `RoadNetwork`） |

**代价要讲清楚**：街区里的人数与分布是**看起来合理**，不是**与真实相符**。
如果以后想要真实感，**唯一需要做的**是给某个活动标签接一个数据源适配器——移动层不用动。

---

## 3. 许可与合规

1. **署名（硬要求）**：`docs/CREDITS.md` + 游戏内"数据来源"页，写明
   `Source: Project PLATEAU, Ministry of Land, Infrastructure, Transport and Tourism (MLIT)`
   并附各自治体的许可与数据版本日期。
2. **多许可要逐数据集记录**：PLATEAU 是 CC BY 4.0 / 政府標準利用規約 / ODbL / ODC-BY 混用，
   **不能笼统写"CC BY 4.0"**。M0 要把所选自治体的实际许可抄进 `CREDITS.md`。
3. **SDK 与被依赖库的许可**：`godot-plateau` 是 MIT；`libplateau` 另有许可 → 两者都要记录。
4. **数据不入库**：数据是 GB 级，且 ODbL 部分带 share-alike，进库会给 MIT 仓库的资产包
   附加义务。改为脚本下载 + 本地/构建目录，`gitignore`；紧凑产物另走 Release 资产。
5. **不要声称官方支持**：SDK 是社区项目；文档与 credits 里都要如实写。

---

## 4. 管线（尽量用 SDK，少自建）

原荷兰方案要自建"CityJSON→GLB + BGT→路网 + AHN→高度场"三段；现在大部分由 SDK 承担。

```
tools/plateau/
  fetch_city.py        按自治体/区域从 G空間情報センター拉取 CityGML（+ 3D Tiles 若有）
  inspect.py           列出地物类型、LOD、bldg:usage 取值分布  ← 决定标签词表是否够用
  build_activity.py    CityGML 属性 → 地点表（id, usage, 坐标, 高度, 层数）→ 规范活动标签
  verify.py            抽样检查坐标轴序、地物计数、usage 覆盖率
  manifest.json        map id、自治体、数据版本、许可、署名、原点、瓦片索引
```

- **网格生成交给 SDK**（`Importer` / `CityModelScene` / `DynamicTile`），不再自建转换器。
- **路网交给 SDK 的 `RoadNetwork`**（若不足则回退用 交通(道路) LOD1 自己建图）。
- **地形用 PLATEAU 的地形 LOD1 + SDK 的 `HeightMapData` / `HeightMapAligner`**
  （后者负责建筑与地形的高程对齐）。
- **`inspect.py` 是关键一步**：先把所选城市实际出现的 `bldg:usage` 取值列出来，
  再决定要不要往 `ActivityTag` 加词。**别假设词表就是我写的那套**。

---

## 5. 运行时架构改动

### 5.1 `MapSource` 抽象（不变）
```
src/map/
  map_source.gd          接口：构建世界、回答地表问题、给出出生点、提供地图身份
  island_map_source.gd   把现有 terrain_config/terrain_generator/world_scatter 收进来
  plateau_map_source.gd  城市实现：SDK 加载 + 分块 + 碰撞 + 地点表 + 移动性
  map_registry.gd        服务：按 id 解析当前地图；mod 可注册
```
`WorldBuilder` 改为询问 `map_registry`，不再直接持有 `TerrainGenerator`。

### 5.2 泛化 `TerrainQuery`（现有接口里最硬的耦合）
`island_falloff(x,z)` 是岛屿专用（散布的 `interior_bias` 与 mod 都在用）。城市里没有"离岛中心多远"。
→ 新增 `surface_mask(x,z) -> float` 与 `surface_kind(x,z) -> StringName`
（`road` / `sidewalk` / `water` / `building` / `green`）；岛屿实现把旧语义适配过去，
旧名保留为**弃用别名**。

### 5.3 坐标、轴序与浮点精度
- PLATEAU 是 **EPSG:6697**。**已知坑：数据里前两个坐标轴顺序是反的**（多个独立来源记录过），
  读进来会落到地球另一边。SDK 声称做坐标转换，**但 M0 必须实测**。
- 街区中心平移到 **(0,0,0)**，平移量写进 manifest 的 `origin`；单精度下这是避免远处抖动的第一道防线。
- 预留 `world_origin_offset()` 作为将来**浮动原点**的唯一接入点。

### 5.4 存档语义必须改（容易漏掉的连带影响）
现有哲学是"**只存一个整数种子，世界由种子确定重生成**"。**PLATEAU 地图不是种子生成的**，
是从数据加载的。所以要有**地图身份**：`map_id`（自治体 + 区域 + 数据版本 + 内容哈希），
读档时校验，不匹配要明确报错，而不是把玩家静默放进另一座城市。

### 5.5 行人 / 车辆 agent 与现有系统
- **导航**：用 SDK 的 `RoadNetwork` 或 交通(道路) LOD1 建图 → `NavigationServer3D` 烘焙；
  车辆用另一份可通行子图。
- **分级 LOD**：近处 `NavigationAgent3D` + 独立节点（可交互）；远处 **MultiMesh 沿路径采样**
  ——与现有 `world_scatter.gd` 同构。
- **可交互性零侵入**：个体做成 **`Interactable`**（复用玩家探测/提示/`E` 键），
  "载人"复用**载具座位**机制 → 玩家、HUD、输入映射各 **0 行**改动。
- **碰撞要自己生成**：CityGML 是可视化级的网格，不是物理级的。参考做法是**建筑外壳自动生成
  碰撞体**（boxes/凸包），但对**细长与复杂几何需要人工校验**（公开发表的工作明确记录了
  近似碰撞会产生意料之外的阻挡与缝隙）。碰撞体只对玩家半径内的建筑启用。

### 5.6 地图无关的移动核心（**已实现**，`src/mobility/`）

只要地图的**地点被标注**，行为就能跑——这一层不依赖任何数据集或插件。

```
activity_tag.gd         规范活动标签 + 别名表（＝数据源适配器，日语 PLATEAU 用途已内置）
activity_pattern.gd     一天的活动序列（家→公司→饭店→公司→家）+ 内置模式
destination_chooser.gd  按 标签 + 距离/权重 选具体地点
route_cache.gd          路线缓存：共享 / 有界 / 换地图版本必须清空 / 局部失效
agent_route.gd          模式 → 具体地点；创建时解析目的地，逐段懒加载路径
```

要点（每条都是"换地图不会坏"的来源）：
1. **别名表就是适配器**：PLATEAU 的 `住宅/事務所/飲食店/店舗/学校/病院/体育館/駅舎`
   以及 `office/Kantoorfunctie/公司` 全部落到同一套规范标签。归一化大小写不敏感、
   **分隔符直接丢弃**（`fast food`=`fast-food`=`fastfood`）、非 ASCII 原样保留。
2. **回退阶梯 = 薄地图不塌**：没有 `food` 就 `food→shop→leisure→service→other` 逐级退让；
   某步无解就跳过并**计数**，让调用方报告"标注太薄"，而不是让个体原地站着。
3. **距离可注入**：`score = weight/(1+d/scale)^decay`；`set_distance_function()` 可接真实路网
   行程距离，默认欧氏 → 现在就能跑，接导航时行为逻辑不变。
4. **按种子加权采样，不取最大值**：取最大值会让同模式的个体全挤进同一栋楼；同 seed 仍必定复现。
5. **路线初始化**：目的地解析在**创建时**（便宜）；**只有第一段路径**立即算，其余按需走共享缓存
   ——否则世界加载会一次性发起几千次寻路查询。
6. **缓存键含地图版本，版本变化清空整表** → 这是"换地图后个体不穿墙"的保证。
   `invalidate_touching(place)` 处理局部改动。**空结果不入缓存**。
7. **只有两个注入点**：`set_distance_function()` / `set_path_finder()`；这一层永远不知道
   `NavigationServer3D` 存在。

断言见 `tools/check_runtimes.ps1`（当前 **151** 条，其中移动核心 **68** 条，
含 13 条日语 PLATEAU 用途映射）。

### 5.7 完整管线（数据源在此接入）

```
PLATEAU CityGML  ──(SDK: 网格/LOD/坐标)──▶  街区网格 + 地形 + 路网
        │
        └──(build_activity.py: bldg:usage)──▶  地点表（规范活动标签）
                                                  │
活动模式（家→公司→饭店→公司→家）  ────────────────┤
                                                  ▼
                              个体：创建时解析目的地 → 首段立即取路径
                              其余段按需 → RouteCache（地图版本为键）
                                                  ▼
                              近处 NavigationAgent3D / 远处 MultiMesh 采样
```

---

## 6. 里程碑与验收

| 阶段 | 内容 | 验收（可执行） |
|---|---|---|
| **M0 可行性 spike**（纯验证，不写产品代码） | ① **SDK 能否在 Godot 4.7.2 加载**（头号问题）；② 下载 1 个自治体的 CityGML，用 SDK 导入并确认**坐标落点正确（轴序）**；③ 确认 `bldg:usage` 的实际取值分布（`inspect.py`）；④ 目视确认**平视纹理粗糙度是否可接受**；⑤ 抄录该自治体的实际许可；⑥ 实测碰撞体生成在细长几何上的表现 | 一栋楼在 Godot 里**位置正确**且无报错；产出 spike 结论 + **SDK 路线 / Blender 路线**二选一的决策；`CREDITS.md` 的许可与数据版本填好；`bldg:usage` 覆盖率的数字 |
| **M1 地图接缝** | `MapSource` 抽象 + `IslandMapSource`（收编现有岛屿代码）；`TerrainQuery` 泛化；`GameState`/存档加**地图身份** | 四件套全绿，且**岛屿世界数值与基线逐项一致**（硬验收：证明没改坏现有地图）；旧存档可读 |
| **M2 城市街区可用** | `PlateauMapSource`：SDK 加载 + 分块 + **建筑碰撞**（含细长几何的人工校验）+ 出生点=人行道；`check_city.ps1` + **合成街区 fixture** | 能在街区里走、上车、不能穿墙；`check_city` 绿；**CI 不需要下载 PLATEAU 数据** |
| **M3 移动性接入** | `build_activity.py` 产出地点表；把 `set_path_finder` 接到 `NavigationServer3D`；个体分级 LOD；时段加速。**地图无关的核心已完成**（§5.6） | agent 数量与帧率达标；**同 seed 同行程**可复现；个体能沿真实路网走完全天 |
| **M4 可交互个体** | 个体状态机 + `Interactable` 接入 + 载人（复用载具）+ 跟踪/跟随 UI | 能跟一个人一整天；能载他一程并**真的改变他的行程** |
| **M5 流式与扩展** | SDK 的 `DynamicTile` 接分块流式；浮动原点；`add_map_source` mod 扩展点 | 走出街区不崩、无明显抖动；mod 能注册自己的地图 |
| **M6 许可与发布** | `CREDITS.md`；游戏内数据来源页；下载脚本 + Release 资产；README 更新 | 署名可见且完整；仓库体积未增长 |

---

## 7. CI 策略（无头测试不能被大数据绑架）

- 仓库内只放 **KB 级合成街区 fixture**（正交路网 + 方块楼 + 少量 `bldg:usage` 标签），
  跑的是**与真实城市完全相同的运行时代码路径**。
- 新增 `tools/check_city.ps1`，与现有三件套并列：合成街区能加载、能走、建筑不可穿透、
  agent 数量正确、**同输入产生同一批行程**。
- SDK 当**可选依赖**：CI 不装 SDK 时，城市路径必须走**降级分支**并在自检里断言这段分支。
- 沿用既有教训：`--quit-after` 防挂、完成标记断言、新加 `class_name` 后刷新全局类缓存。

---

## 8. 性能预算（初值，M2/M3 据实调）

| 项 | 目标 |
|---|---|
| 街区范围 | 2–3 km²（LOD1/2 混合） |
| 建筑数 | 2,000–8,000，每栋一个外壳碰撞体（**仅玩家半径 150 m 内启用**） |
| 常显 agent | 100–300 个独立个体（可交互） |
| 背景 agent | 1,000–3,000（MultiMesh，无独立物理） |
| 街区加载时间 | < 5 s |
| 三角形预算 | 视距内 < 300 万 |

---

## 9. 风险登记

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| **1** | **SDK 声称 Godot 4.5，本工程 4.7.2**，且版本已 7 个月未更新 | 直接走不通 | M0 **第一件事**就实测；不行退**Blender 转换桥**路线；SDK 始终当**可选**依赖（`ClassDB` 探测 + 优雅降级，绝不写进 `project.godot`） |
| 2 | **CityGML 的坐标轴序是反的**（EPSG:6697） | 整张地图落到地球另一边 | M0 实测落点；不信任 SDK 的转换，抽样验证 |
| 3 | **纹理 10 cm/pixel，平视粗糙** | 观感 | M0 目视评估；可选"LOD2 不带纹理 + 自有材质风格化"，或接受俯瞰优先 |
| 4 | **碰撞体要自建**；CityGML 是可视化级网格 | 细长/复杂几何出现意外阻挡或缝隙 | 外壳自动生成 + 抽样人工校验；碰撞只对半径内启用；把已知问题写进 README |
| 5 | **多许可混用**（CC BY 4.0 / 政府標準利用規約 / ODbL / ODC-BY） | 合规 | 逐数据集抄录到 `CREDITS.md`；ODbL 部分隔离存放；**不笼统写 CC BY 4.0** |
| 6 | **非官方社区 SDK** | 维护风险、误导 | 文档与 credits 如实标注"非官方"；锁定版本；关键路径不依赖单个插件 |
| 7 | OBJ 导出每栋一个 group → **Godot 单网格 256 面上限** | 导入报 MAX_MESH_SURFACES | 用 **AREA 粒度**合并；优先走直接加载而非导出 |
| 8 | 水域（河川/運河） | 现有"海面只是着色器平面、没有水下玩法" | 水域掩码 + 不可行走；明确列为已知边界 |
| 9 | 城市地形平坦，现有"坡度筛选"假设失效 | 散布/选址逻辑无意义 | 用 `surface_kind` 取代坡度作为主筛选；街道家具替换植被散布 |

---

## 10. 与现有 mod 系统的关系

- 城市地图是**核心内置**的 `MapSource`（它是默认地图），同时开扩展点
  **`context.add_map_source(id, factory)`**，让 mod 提供自己的地图。
- 活动词表与活动模式以**数据**形式暴露，mod 可覆盖/扩充：**换语言、换城市、换文化习惯
  都不需要改核心代码**（`ActivityTag` 的别名表就是为此设计的）。
- 城市地图上的地标、物品、战斗、载具**继续走现有扩展点**，
  所以 `mods/lighthouse`、`mods/garage` 这类 mod 仍然有意义（语义要重写）。

---

## 11. 下一步

**M0 是纯验证阶段，不写产品代码**，但它决定后面一切：
最关键的单一问题是 **`godot-plateau` 能不能在 Godot 4.7.2 上加载**。
其次是把所选自治体的 **`bldg:usage` 实际取值分布**拉出来——如果实际词表比我内置的
13 条映射更丰富（很可能），那就是继续往别名表加词的问题，**不是设计问题**。
