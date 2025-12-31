import requests
import time
import datetime

# ==================== 用户配置区域 ====================
# 1. Qmsg KEY
QMSG_KEY = "你的Qmsg KEY"

# 2. 目标硬件配置 (严格匹配您提供的 JSON 字段)
TARGET_MEMORY = "ram-64g-ecc-2133"      # 64G 内存
TARGET_STORAGE = "softraid-2x450nvme"   # NVMe 硬盘 (排除 SATA)

# 3. 目标区域代码 (Plan Codes)
#    ca = 加拿大, us = 美国, eu = 欧洲，这三个合起来就是North Ameri ca - Europe
#    sgp(Singapore) = 新加坡，syd(Sydney) = 悉尼
#    脚本会依次轮询这三个区域
TARGET_REGIONS = ["24sk202-ca", "24sk202-us", "24sk202-eu"]
# TARGET_REGIONS = ["24sk202-sgp", "24sk202-syd"]

# 4. API 基础地址 (动态拼接 planCode)
BASE_API_URL = "https://eco.us.ovhcloud.com/engine/api/v1/dedicated/server/datacenter/availabilities/"

# ====================================================

def send_qmsg(msg):
    if "替换" in QMSG_KEY:
        print("❌ 请先配置 Qmsg KEY")
        return
    try:
        # 使用 Session 可以复用 TCP 连接，稍微提高性能
        with requests.Session() as s:
            s.post(f"https://qmsg.zendee.cn/send/{QMSG_KEY}", data={"msg": msg}, timeout=5)
        print("✅ 消息已推送")
    except Exception as e:
        print(f"❌ 推送失败: {e}")

def check_stock_for_region(plan_code):
    """
    检查指定区域代码的库存
    """
    url = f"{BASE_API_URL}?excludeDatacenters=false&planCode={plan_code}"
    
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "application/json"
    }

    try:
        response = requests.get(url, headers=headers, timeout=15)
        
        if response.status_code != 200:
            # 某些区域 (如 eu) 在 us 接口可能偶尔 404 或空，视为暂时无数据
            print(f"⚠️ [{plan_code}] API 响应异常: {response.status_code}")
            return False

        data = response.json()
        
        # 遍历该区域下的所有配置变体 (SATA, NVMe, 32G, 64G 等)
        for item in data:
            # 1. 硬件指纹匹配 (内存 + 硬盘)
            #    直接对比字符串，这是最稳妥的白盒匹配方式
            mem_match = item.get('memory') == TARGET_MEMORY
            disk_match = item.get('storage') == TARGET_STORAGE
            
            if mem_match and disk_match:
                # 2. 检查该配置下的数据中心列表
                datacenters = item.get('datacenters', [])
                for dc in datacenters:
                    dc_code = dc.get('datacenter')
                    availability = dc.get('availability')
                    
                    # 3. 核心判断：只要不是 unavailable 就是有货
                    #    (1H-high, 24H, 72H 都算可订购)
                    if availability != "unavailable":
                        print(f"\n🎉 命中库存!!! 区域: {plan_code} | 机房: {dc_code} | 状态: {availability}")
                        
                        msg = (
                            f"OVH 补货监控\n"
                            f"区域代码: {plan_code}\n"
                            f"机房: {dc_code.upper()}\n"
                            f"配置: 64G + NVMe\n"
                            f"交付时效: {availability}"
                        )
                        send_qmsg(msg)
                        return True
                        
    except Exception as e:
        print(f"❌ [{plan_code}] 请求错误: {e}")
    
    return False

def main_loop():
    print(f"--- 监控启动 ---")
    print(f"目标区域: {TARGET_REGIONS}")
    print(f"目标硬件: 64G RAM + 2x450 NVMe")
    
    while True:
        current_time = datetime.datetime.now().strftime('%H:%M:%S')
        print(f"[{current_time}] 正在扫描轮询...")
        
        stock_found = False
        
        # 依次检查每个区域
        for region in TARGET_REGIONS:
            if check_stock_for_region(region):
                stock_found = True
        
        if stock_found:
            # 如果发现库存，延长休眠时间，避免重复轰炸
            # 同时也给自己预留去官网下单的时间
            print(">>> 发现库存，脚本暂停 5 分钟...")
            time.sleep(300)
        else:
            # 无库存，休息 30 秒 (请求过于频繁可能触发 HTTP 429)
            time.sleep(30)

if __name__ == "__main__":
    main_loop()