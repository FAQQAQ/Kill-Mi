# Kill Mi-针对小米遥测等组件的模块

一个针对小米XSOF/反诈组件，系统遥测等组件隐藏的模块。
## 本模块干了什么？

1. **遮蔽五个独立应用**：系统安全组件（GuardProvider）、SystemHelper、MiTrustService、统计分析和运营商服务。除系统安装目录，还覆盖已核对的 mi_ext、pangu 来源和开机时存在的 `/data/app` 更新副本。（统计分析和运营商服务如果未能遮蔽，则使用冻结措施。）
2. **禁用手机管家内五个指定 XSOF / 反诈组件**。
3. **hosts 开启时屏蔽 21 个精确域名**。
4. **UID 防火墙兜底拦截 SystemHelper、GuardProvider**：这两个应用重新出现且使用独占普通应用 UID 时，阻止其 IPv4 / IPv6 出站联网。

## 模块食用方法

1. **KernelSU / SukiSU 用户**需安装 Hybrid Mount 或其他适用的挂载元模块，否则目录遮蔽和 hosts 挂载无法生效。Magisk 使用自身的模块挂载机制。
2. 根据提示安装模块，音量加确认、音量减取消，安装完成后重启。如果检测到去广告等其他模块冲突，本模块会自动关闭自己的 hosts 屏蔽。
3. Enjoy！
使用 Hybrid Mount 时，若目标 APK 仍可见，或出现 SELinux 标签复制失败，请将 Kill Mi 单独设为 Magic Mount再次尝试。
请仔细排查冲突模块，特别是去广告类，可能会导致安装失败。

## 模块有什么影响吗？

有。地震预警、地震监测志愿者、报警快速定位等功能可能不可用，相关反诈功能也会受影响。

ADB 安装验证、运营商设备注册、云查杀及部分云端规则更新也可能受影响。WebUI 关闭 hosts 并重启后，可以撤销这一层域名屏蔽；目录遮蔽、组件禁用和 UID 防火墙兜底仍然生效。

部分域名由多项业务共用，按整个域名屏蔽会一起影响这些功能。检测到其他模块提供标准 hosts 文件时，自动关闭的是**本模块的 hosts 屏蔽**，方便把域名交给现有软件处理；21 个域名可以在 WebUI 中查看、复制。

遮蔽 `/data/app` 更新副本后，系统可能清理对应应用的更新和私有数据。

---

模块源码放在 [module/](module/)；打包时进入该文件夹，压缩里面的内容即可。逆向分析资料见 [HyperOS4-XSOF Analysis](https://github.com/FAQQAQ/HyperOS4-XSOF-Analysis)。

安装入口沿用 [Magisk 模板](https://github.com/topjohnwu/Magisk/blob/master/scripts/module_installer.sh)，本模块由GPT-6.1 Sol辅助制作，该上游采用 [GPL-3.0](https://github.com/topjohnwu/Magisk/blob/master/LICENSE)。
