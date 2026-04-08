# AdGuardHome-Keenetic
AdGuard Home installer for KeeneticOS 5.x

Минималистичный установщик и менеджер AdGuard Home для KeeneticOS 5.x

## 🚀 Установка
```bash
curl -sSL https://raw.githubusercontent.com/arl-spb/AdGuardHome-Keenetic/main/installer/setup-AdGuardHome.sh | sh
```

## ⚙️ Управление
Все команды доступны из любого каталога после установки:

| Команда | Действие |
|:---|:---|
| `setup-AdGuardHome update` | Обновить до последней версии |
| `setup-AdGuardHome uninstall` | Удалить сервис (конфиги сохранятся) |
| `S99adguardhome restart` | Перезапустить AdGuard |
| `S99adguardhome status` | Проверить статус |

## 🌐 Веб-интерфейс
Откройте в браузере: `http://192.168.1.1:3000`
