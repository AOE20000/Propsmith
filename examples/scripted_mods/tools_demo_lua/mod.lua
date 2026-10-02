-- Lua 版的 P3 验收 mod：与 mods/tools_demo（GDScript 版）完全等价。
-- 需要先安装 Lua GDExtension（addons/lua-gdextension），否则本 mod 会被
-- 判为加载失败并给出安装指引——这正是探测与降级的设计行为。
--
-- 三个注册点各演示一次：回调式工具、Mesh 道具、Mesh NPC。
-- 桥接层负责包装：工具回调进 CallbackTool，Mesh 进刚体/行人 agent。

local marked = {}

function on_register(game)
    game:set_display_name("工具演示（Lua）")
    game:set_version("1.0.0-lua")

    game:add_tool("lua_mark", "标记（Lua）", {
        on_primary = function(hit)
            local collider = hit.collider
            if collider == nil then return end
            game:notify("Lua 工具命中：" .. tostring(collider.name))
        end,
        on_secondary = function(_hit)
            marked = {}
            game:notify("Lua 标记已清空")
        end,
    })

    game:add_prop("lua_glow_orb", function()
        local sphere = SphereMesh.new()
        sphere.radius = 0.25
        sphere.height = 0.5
        return sphere
    end, "发光球（Lua）")

    game:add_npc("lua_guard", "卫兵（Lua）", function()
        local capsule = CapsuleMesh.new()
        capsule.radius = 0.26
        capsule.height = 1.5
        return capsule
    end)

    game:log("已注册：标记工具、发光球道具、卫兵 NPC")
end

function on_tick(_delta) end

function serialize() return {} end
function deserialize(_data) end

function on_unload()
    marked = {}
end
