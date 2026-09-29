# AdGuardHome-Keenetic
AdGuard Home installer for KeeneticOS 5.x

Минималистичный установщик и менеджер AdGuard Home для KeeneticOS 5.x


## Архитектура

AdGuard Home интегрирован с Keenetic через две точки:

- **S99adguardhome** — при старте резолвит mark политики `adguard-clients`
  через RCI (`/rci/show/ip/policy`) и сохраняет его в `/tmp/.agh/policy-mark`.
- **99-adguard-dns.sh** — netfilter-хук, который читает mark из файла и
  ставит DNAT-правила для DNS-трафика клиентов политики.

Mark резолвится в init-скрипте, а не в хуке, потому что NDM вызывает
netfilter.d слишком рано — до того, как политики становятся видны через
`ndmc`/RCI. Это архитектурный паттерн, аналогичный XKeen и nfqws-keenetic.


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
