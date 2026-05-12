# olcrtc-manager-panel

Веб-панель и менеджер процессов для запуска нескольких серверных инстансов `olcrtc`.

Версия 2 включает:

- админ-панель на `/admin`;
- настройку пароля при первом запуске;
- создание, редактирование и удаление клиентов, ротацию room/key, рестарт, логи, QR-коды и экспорт подписок;
- отдельные подписки для клиентов на `/<client-id>/`;
- метаданные квот трафика в подписках;
- автоматический учет входящего трафика;
- блокировку по лимиту трафика и сроку действия;
- ограничение скорости через отдельный `network namespace` + `veth` для каждого клиента;
- один изолированный процесс `olcrtc` на каждую локацию клиента.

## Быстрая установка

Запустите на Linux-сервере с systemd:

```sh
curl -fsSL https://raw.githubusercontent.com/BigDaddy3334/olcrtc-manager-panel/main/install.sh | sudo bash
```

Установщик:

- устанавливает/проверяет runtime-инструменты: `ip`, `iptables`, `tc`, `systemctl`;
- устанавливает `/usr/local/bin/olcrtc-manager`;
- устанавливает `/usr/local/bin/olcrtc`;
- создает `/etc/olcrtc-manager/config.json`, если его еще нет;
- устанавливает и запускает `olcrtc-manager.service`;
- не создает `/etc/olcrtc-manager/panel.env`, чтобы сработала настройка пароля при первом запуске.

По умолчанию панель слушает `127.0.0.1:8888`:

```text
http://127.0.0.1:8888/admin
```

Для прямого доступа используйте `--addr 0.0.0.0`, либо оставьте значение по умолчанию и опубликуйте панель через обратный прокси.

Если в GitHub Releases есть готовые бинарники, установщик использует их. Иначе он скачивает архивы исходников и собирает все во временной директории. Для `olcrtc` это сейчас обычный путь, потому что основной репозиторий не публикует бинарники релизов.

## Опции установщика

Частые примеры:

```sh
# Использовать другой порт.
curl -fsSL https://raw.githubusercontent.com/BigDaddy3334/olcrtc-manager-panel/main/install.sh | sudo bash -s -- --port 8080

# Слушать на всех интерфейсах. В боевом окружении используйте firewall или обратный прокси.
curl -fsSL https://raw.githubusercontent.com/BigDaddy3334/olcrtc-manager-panel/main/install.sh | sudo bash -s -- --addr 0.0.0.0

# Использовать явные бинарные артефакты вместо сборки.
curl -fsSL https://raw.githubusercontent.com/BigDaddy3334/olcrtc-manager-panel/main/install.sh | sudo bash -s -- \
  --panel-url https://example.com/olcrtc-manager-linux-amd64 \
  --olcrtc-url https://example.com/olcrtc-linux-amd64
```

Полезные переменные окружения:

- `PANEL_REF`: ветка/тег/commit этого репозитория, по умолчанию `main`;
- `OLCRTC_REF`: ветка/тег/commit репозитория `openlibrecommunity/olcrtc`, по умолчанию `master`;
- `PORT`: порт панели, по умолчанию `8888`;
- `LISTEN_ADDR`: адрес прослушивания, по умолчанию `127.0.0.1`;
- `ROOM_ID` и `ENDPOINT_KEY`: использовать заранее сгенерированные начальные значения endpoint;
- `SPEED_MBPS`, `TRAFFIC_GB`, `EXPIRES_AT`: начальная квота клиента по умолчанию.

По умолчанию установщик сохраняет существующий конфиг. Передайте `--force-config`, чтобы заменить его; старый файл будет сохранен с суффиксом-временной меткой.

## Ручная сборка

Сначала соберите ассеты фронтенда, затем Go-бинарник, чтобы панель была встроена в менеджер:

```sh
pnpm install
pnpm build
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o olcrtc-manager ./cmd/olcrtc-manager
```

Затем установите:

```sh
sudo install -m 0755 olcrtc-manager /usr/local/bin/olcrtc-manager
sudo install -m 0755 olcrtc /usr/local/bin/olcrtc
sudo install -d -m 0755 /etc/olcrtc-manager
sudo install -m 0600 config.json /etc/olcrtc-manager/config.json
sudo install -m 0644 packaging/systemd/olcrtc-manager.service /etc/systemd/system/olcrtc-manager.service
sudo systemctl daemon-reload
sudo systemctl enable --now olcrtc-manager
```

## Первый запуск

Откройте панель:

```text
http://127.0.0.1:8888/admin
```

Если `/etc/olcrtc-manager/panel.env` не существует или не содержит пароль, панель запускается в режиме первого запуска и попросит задать пароль администратора.

После настройки менеджер записывает:

```sh
/etc/olcrtc-manager/panel.env
```

Пример содержимого:

```sh
OLCRTC_MANAGER_USER='admin'
OLCRTC_MANAGER_PASS='your-password'
```

После этого панель использует cookie-сессии для входа. Позже пароль можно изменить кнопкой `Пароль` в шапке панели.

## Обратный прокси

По умолчанию менеджер слушает `127.0.0.1`. Чтобы опубликовать его через nginx:

```nginx
server {
    listen 9443 ssl http2;
    server_name example.com;

    ssl_certificate /path/fullchain.pem;
    ssl_certificate_key /path/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8888;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Затем откройте:

```text
https://example.com:9443/admin
```

## Конфигурация

Минимальный конфиг:

```json
{
  "version": 1,
  "name": "OlcRTC VPS",
  "port": 8888,
  "clients": [
    {
      "client-id": "default",
      "quota": {
        "speed_mbps": 10,
        "traffic_gb": 100,
        "expires_at": "2026-12-31"
      },
      "locations": [
        {
          "name": "Current VPS",
          "endpoint": {
            "room_id": "room-01",
            "key": "e830d36f7be8cfb04a741fc1a5e2ddf8ff04f30985dc070616483f939ad5fafe"
          },
          "carrier": "wbstream",
          "transport": {
            "type": "datachannel"
          },
          "link": "direct",
          "data": "data",
          "dns": "1.1.1.1:53"
        }
      ]
    }
  ]
}
```

Поля квоты:

- `speed_mbps`: ограничение скорости для локации клиента. `0` или отсутствие поля означает без ограничений.
- `traffic_gb`: лимит трафика. `0` или отсутствие поля означает без ограничений.
- `used_bytes`: автоматически обновляется менеджером.
- `used_gb`: производное/устаревшее значение для отображения.
- `expires_at`: необязательная дата окончания в формате `YYYY-MM-DD`.

Старый верхнеуровневый формат `locations` все еще поддерживается и нормализуется в `clients`.

`endpoint.room_id` должен быть конкретным. Значение `any` отклоняется.

## Сетевая изоляция и лимиты

Для каждой запущенной локации менеджер создает:

- сетевой namespace: `olc-*`;
- host veth: `olh*`;
- namespace veth: `oln*`;
- NAT-правило для исходящего трафика из namespace;
- DNS-файл в `/etc/netns/<namespace>/resolv.conf`;
- опциональный лимит скорости `tc tbf` на обеих сторонах veth.

Полезные проверки:

```sh
ip netns list
ip -br link | grep olh
tc qdisc show dev olhXXXXXXXX
ip netns exec olc-XXXXXXXX tc qdisc show
iptables -t nat -S POSTROUTING | grep olcrtc-manager-netns
```

Учет трафика использует `tx_bytes` host veth, то есть трафик, отправленный с VPS в namespace клиента. Когда настроенная квота трафика превышена, менеджер останавливает локацию этого клиента. Если увеличить `traffic_gb` выше `used_bytes`, reload/restart снова запустит ее.

## Подписки

Подписка клиента:

```text
http://127.0.0.1:8888/<client-id>/
```

Если квота настроена, подписка содержит ее метаданные:

```text
#quota-speed-mbps: 10
#quota-traffic-gb: 100
#quota-used-gb: 5
#quota-used-bytes: 5368709120
#quota-expires-at: 2026-12-31
#quota-status: active
```

Возможные статусы квоты:

- `active`
- `expired`
- `traffic_exceeded`

## Перезагрузка конфигурации

Перезагрузить конфиг и применить изменения клиентов без рестарта неизмененных процессов:

```sh
sudo systemctl reload olcrtc-manager
```

Или локально:

```sh
curl -X POST http://127.0.0.1:8888/-/reload
```

## API и авторизация панели

На свежей установке пароля по умолчанию нет. Настройку первого запуска нужно завершить через `/admin`.

После настройки:

- вход в UI использует cookie-сессию;
- Basic auth по-прежнему работает для скриптов и `curl`;
- пароль можно изменить из панели.

## Вспомогательные скрипты

В `scripts/` есть небольшие скрипты для редактирования JSON-конфига:

```sh
scripts/add-user.sh /etc/olcrtc-manager/config.json alice --from default
scripts/modify-user.sh /etc/olcrtc-manager/config.json alice --location-name Germany --room-prefix alice-room
scripts/delete-user.sh /etc/olcrtc-manager/config.json alice
```

Передайте `--reload http://127.0.0.1:8888/-/reload`, чтобы перезагрузить запущенный менеджер после сохранения конфига.
