#!/bin/bash
# 选中文本通过 POPBAR_TEXT 环境变量传入;这里转成大写并写回剪贴板
printf '%s' "$POPBAR_TEXT" | tr '[:lower:]' '[:upper:]' | pbcopy
