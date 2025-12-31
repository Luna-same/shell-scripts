本仓库是个人使用的 shell 脚本集合

# 脚本说明
## ovh-delivery-monitor.py
ovh-delivery-monitor.py是一个用于监控ovh服务器上货状态的脚本。

在ovhcloud 选购界面打开开发者工具，并筛选availabilities的请求，点击响应预览里面都是页面调用API的JSON数据，可以将其发给AI并指定自己想要的硬件选项；听AI说他家的字段老是修改，所以自己执行的时候发给AI写

> 1. 注意美国账号和全球服务器是分开的，所以网址要注意
> 2. 一般的VPS厂商防止邮件轰炸基本上都是关了邮件端口的，qq官方的机器人也是关闭使用了的，所以得使用[Qmsg酱-您的专属QQ消息推送服务小姐姐-qmsg.zendee.cn](https://qmsg.zendee.cn/)推送机器人
> 3. 注意内容不要违规，或者你也可以自己搭一个私有云机器人

## install-docker.sh
install-docker.sh脚本是从[docker官方脚本](https://get.docker.com)下载的

## host-init.sh