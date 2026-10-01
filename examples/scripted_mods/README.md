# 脚本化 mod 范例

这里的东西**不会被自动加载**：`ModHost` 只扫描 `res://mods/`，而本目录在它之外。
这样范例可以安全地待在仓库里，即使对应的 GDExtension 没装也不会产生失败日志。

想试用哪一个，就把那个目录整体复制到 `res://mods/` 下，并先确保装好了它需要的
运行时（见 [../docs/SCRIPTED_MODS.md](../docs/SCRIPTED_MODS.md)）。

| 目录 | 需要 | 变成可用的前提 |
|---|---|---|
| `lua_crystals/` | Lua GDExtension | 装上扩展即可，源码直接运行 |
| `sgd_tower/` | Godot Sandbox | 装上扩展后**还要把 `mod.sgd` 编译成 `mod.elf`** |

`sgd_tower/` 之所以要多一步：Godot Sandbox 运行的是编译后的 ELF 程序，源码本身
不是可执行产物。把源码放进 mod 目录只是为了随目录一起携带；缺编译产物时加载器会
明确说明这一点。
