# 音频来源与许可

本目录下的音频**不是**本项目原创，各自的原始许可**不受**项目 MIT 协议覆盖。
四条都来自 **BigSoundBank**（LaSonotheque），作者 **Joseph SARDIN**，
许可 **CC0 1.0（公有领域等价）**——可商用、可修改、可再分发，**无需署名**。
本项目仍然逐条登记，因为"许可允许不署名"不等于"来源可以不记"。

完整法律文本：<https://bigsoundbank.com/licenses.html>
（该站声明其音频以 "public-domain equivalent"（CC0 / WTFPL / public domain）释出。）

## 逐条登记

| 本项目文件 | 原始作品 | 作者 | 许可 |
|---|---|---|---|
| `ambience_forest.ogg` | [Forest #4](https://bigsoundbank.com/forest-4-s2749.html)（编号 2749） | Joseph SARDIN | CC0 1.0 |
| `ambience_night.ogg` | [Campaign at night #3](https://bigsoundbank.com/campaign-at-night-3-s1469.html)（编号 1469） | Joseph SARDIN | CC0 1.0 |
| `ambience_city.ogg` | [Aubervilliers Street](https://bigsoundbank.com/rue-d-aubervilliers-s2722.html)（编号 2722） | Joseph SARDIN | CC0 1.0 |
| `water_stream.ogg` | [Flowing water](https://bigsoundbank.com/flowing-water-s1522.html)（编号 1522） | Joseph SARDIN | CC0 1.0 |

下载地址形如 `https://bigsoundbank.com/UPLOAD/ogg/<编号>.ogg`（OGG 版本）。

## 本项目对这些文件做了什么

CC0 允许修改与再分发，以下改动逐条记录，以便任何人回溯到原始作品：

1. **截取**：`ambience_forest` / `ambience_night` / `ambience_city` 各取**前 45 秒**
   （原始分别 3:46 / 2:31 / 5:24）。`water_stream` 保留完整 0:33。
   目的是循环长度够用（环境床的常见循环长度是 30–60 秒）而仓库体积可控。
2. **两端 20 ms 淡入淡出**：原始录音是连续的，硬切在循环接缝处会"咔"一声；
   20 ms 穿过零点的淡变听不出来，但把接缝变成了无声。
3. **重编码**：Vorbis `-q:a 4`（原始 OGG 未标注码率）。四条合计 2.3 MB。
   选择 **OGG/Vorbis 而非 MP3**：MP3 的编码器补零会破坏无缝循环。

复现命令（`ffmpeg`）：

```bash
curl -o src.ogg https://bigsoundbank.com/UPLOAD/ogg/2749.ogg
ffmpeg -y -i src.ogg -t 45 \
  -af "afade=t=in:st=0:d=0.02,afade=t=out:st=44.98:d=0.02" \
  -c:a libvorbis -q:a 4 ambience_forest.ogg
```

## 已知的取舍

- **循环接缝不是数学无缝的**：20 ms 淡变消除了咔声，但每 45 秒有一次极短的
  电平凹陷。在作为低音量环境床播放时听不出来，做音乐素材则不够格。
  真要无缝得让截取窗口的两端内容天然接近，或者做一次跨接缝交叉淡化。
- **`water_stream` 是单声道**，这是**刻意的**：它作为 3D 点声源挂在池塘上，
  单声道才能被引擎正确按方位声像化；立体声素材给 `AudioStreamPlayer3D` 会得到
  一个塌掉的声像。
