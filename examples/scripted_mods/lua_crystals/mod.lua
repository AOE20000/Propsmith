-- 用 Lua 写的内容 mod。复制本目录到 res://mods/ 并装好 Lua GDExtension 即可生效。
--
-- 脚本体在加载时执行一次，此时全局 `game` 已经就位；它是 mod 与宿主之间的唯一通道。

game:log("lua 水晶：注册中")

-- 一个散布道具。散布系统负责实例化与材质，mod 只需要返回一个 Mesh。
game:add_prop("lua_crystal", function()
	local sphere = SphereMesh.new()
	sphere.radius = 1.3
	sphere.height = 2.6
	sphere.radial_segments = 7
	return sphere
end, 0.7, 38.0)

game:add_item("lua_shard", { display_name = "水晶碎片", stackable = true })

-- 一个地标。工厂返回 Node3D，发现逻辑由核心的 PoiMarker 负责。
game:add_poi("lua_spire", "水晶尖塔", function()
	local root = Node3D.new()
	local mesh = MeshInstance3D.new()
	local cylinder = CylinderMesh.new()
	cylinder.top_radius = 0.4
	cylinder.bottom_radius = 2.0
	cylinder.height = 14.0
	mesh.mesh = cylinder
	mesh.position = Vector3(0.0, 7.0, 0.0)
	root.add_child(mesh)
	return root
end, 1.0)

-- 事件：参数按位置传入，与 GDScript 侧收到的完全一致。
game:watch("poi_discovered", function(poi_id, display_name, _position)
	if poi_id == "lua_spire" then
		game:notify("水晶尖塔的共鸣传了过来", 1)
	end
	game:log("发现 " .. display_name)
end)

-- 生命周期钩子：可用的名字只有 world_generate / world_populate /
-- player_spawn / tick / unload。
game:on("world_populate", function(_world)
	local height = game:terrain_height(0.0, 0.0)
	game:log(string.format("世界已就绪，岛屿中心高度 %.1f m", height))
end)
