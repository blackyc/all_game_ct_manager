# Tools — 辅助工具

## `ce_bridge_cli.py`

**命令行驱动 Cheat Engine MCP 桥**的小工具(开发辅助用)。

### 背景

本仓库的 CT 是在开发过程中,通过 **Cheat Engine MCP Bridge**(第三方开源项目:Lua 桥 + 命名管道 + Python MCP 服务器)
配合 AI 助手完成数据结构探索的。官方的 MCP 服务器需要被 MCP 客户端(如 Claude/Cursor)拉起,
而本脚本可以**直接从命令行**通过命名管道 `\.\pipe\CE_MCP_Bridge_v99` 调用桥的任意命令,方便脚本化调试。

### 依赖

```bash
pip install pywin32
```

需要 Cheat Engine 里已经加载 `ce_mcp_bridge.lua`(第三方开源项目)。

### 用法

```bash
# 测试连接
python ce_bridge_cli.py ping

# 列出桥暴露的全部命令(约 180 个)
python ce_bridge_cli.py list
python ce_bridge_cli.py list read          # 过滤关键字

# 调用任意命令
python ce_bridge_cli.py call get_process_info
python ce_bridge_cli.py call read_memory "{\"address\":\"0x1234\",\"size\":16}"
python ce_bridge_cli.py call read_integer "{\"address\":\"0x1234\",\"type\":\"float\"}"

# 用文件传参(适合带引号的 Lua 代码)
python ce_bridge_cli.py call evaluate_lua --lua-file my_script.lua
python ce_bridge_cli.py call open_process --params-file params.json
```

### 说明

- 本工具仅用于**开发调试**,使用成品 CT 不需要它
- 与 Cheat Engine MCP Bridge 的通信协议为:4 字节小端长度前缀 + UTF-8 JSON-RPC
