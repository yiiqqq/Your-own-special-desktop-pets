# 角色文件格式 v1

角色文件为 UTF-8 JSON。Mac / Windows 共用如下格式；应用存档与角色文件相互独立。

```json
{
  "format": "little-companions-character",
  "version": 1,
  "name": "我的小伙伴",
  "design": {
    "version": 1,
    "shape": "bean",
    "color": "#a8cdbb",
    "accent": "#efd69c",
    "ears": "none",
    "eyes": "dot",
    "tail": true,
    "persona": "温柔好奇，喜欢探索",
    "images": {}
  }
}
```

- shape: `orb`, `bean`, `droplet`。
- ears: `none`, `round`, `leaf`。
- eyes: `dot`, `spark`。
- 颜色只接受六位十六进制颜色；性格限制 200 字，名字限制 24 字。
- images 的可选键：`neutral`, `happy`, `angry`, `sad`, `excited`, `side`, `back`。值必须为 `data:image/png;base64,...`，不允许 URL、SVG、路径或代码。
- 每张解码后的 PNG 最大 1 MB、尺寸不超过 2048 × 2048；通过图片导入入口时缩小到最大边 512 像素。整个角色文件最大 10 MB。
- 以两端导出的完整字段为准；不能识别的 format / version 拒绝导入。导入时校验和清理外观字段。
- 图片保持宽高比，透明留白由玩家自己安排。当前版本接受完整立绘，不接受可执行脚本或自定义骨骼。
- 文件不包含亲密度、养成、日程、聊天、API 密钥；图片和性格会随文件分享。
