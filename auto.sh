#!/bin/bash

# لود کردن توابع اسکریپت بدون اجرای منوی گرافیکی
export G2RAY_SOURCE_ONLY=1
source ./g2ray.sh

# اگر کانفیگ از قبل وجود نداشت، آن را بساز (شامل دریافت پورت و ساخت لینک‌ها)
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Generating config automatically..."
    generate_config
fi

# اجرای تسک‌های پس‌زمینه و استارت انجین در حالت بی‌صدا
unset G2RAY_SOURCE_ONLY
bash ./g2ray.sh --silent-start
