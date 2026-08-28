# Remnawave Node Bootstrap

Безопасный повторяемый установщик Remnawave Node на чистый VPS. Он разворачивает
закреплённую версию Node, подключает её к существующей Panel по `SECRET_KEY` и
готовит firewall для Hysteria2. Репозиторий не содержит инфраструктурных
адресов, подписок или ключей.

## Что подготовить в Panel

1. Откройте **Nodes → Management → +**.
2. Укажите публичный IP нового VPS и выбранный Node API port (`2222` по
   умолчанию).
3. Скопируйте с карточки одноразово созданный `SECRET_KEY`, но пока не закрывайте
   мастер создания Node.

Не используйте ключ от другой ноды. Административный API token Panel на VPS не
нужен и установщик его не запрашивает.

## Установка — три команды

Запустите на новом Ubuntu VPS от пользователя с `sudo`:

```bash
sudo apt-get update && sudo apt-get install -y git && git clone --branch v1.0.9 --depth 1 https://github.com/Andrey-Panin/remnawave-node-bootstrap.git
cd remnawave-node-bootstrap
sudo bash install.sh
```

Скрипт интерактивно попросит:

- IPv4 главной Remnawave Panel;
- `SECRET_KEY` с карточки Node — ввод скрыт;
- Node API port, по умолчанию `2222/tcp`;
- Hysteria2 port, по умолчанию `10443/udp`;
- подтверждение показанного плана словом `APPLY`.

Пароль/ключ не передаётся через argv, environment или журнал. Он сохраняется
только в `/opt/remnanode/.env` с правами `0600`.

## Завершение в Panel

1. Вернитесь в мастер Node, выберите Config Profile и активный Hysteria2
   inbound, затем завершите создание. Дождитесь **Connected**.
2. Добавьте DNS `A`-запись нового hostname на IP VPS.
3. Создайте Host: новый hostname, эта Node, TLS, ALPN `h3`, выбранный
   Hysteria2 port (`10443` по умолчанию).
4. Добавьте inbound в нужный Internal Squad и обновите подписку пользователя.
5. На VPS выполните `sudo bash status.sh`.

Критично: порт `listen/port` выбранного Hysteria2 inbound в Config Profile,
порт Host и `HY2_PORT` установщика должны быть одинаковыми. Один Host с другим
портом не заставляет Xray слушать этот порт.

TLS-сертификат в выбранном Config Profile должен покрывать SNI нового hostname.
Установщик ноды не выпускает сертификаты и не меняет Panel. Для массового
масштабирования используйте заранее подготовленный профиль сертификатов либо
отдельный сертификат на каждый node hostname.

## Что меняется на VPS

- `/opt/remnanode/docker-compose.yml`;
- `/opt/remnanode/.env` — root-only secret;
- `/opt/remnanode/bootstrap.conf` — только несекретные параметры и hashes
  файлов UFW и фактического firewall ruleset;
- Docker Engine из подписанного официального APT-репозитория, если отсутствует;
- UFW на чистом VPS, если не выбран внешний firewall;
- root-only транзакционный backup в `/opt/remnanode/backups/`.

Контейнер использует `network_mode: host` и capability `NET_ADMIN`, как требует
официальная Remnawave Node. Поэтому VPS должен быть выделен только под эту ноду,
без недоверенных локальных пользователей и посторонних сервисов на её портах.

## Firewall

Стандартный режим рассчитан на чистый VPS:

- текущий SSH port сохраняется;
- Node API разрешён только от IPv4 Panel;
- Hysteria2 разрешён публично по UDP;
- default incoming — `deny`, outgoing — `allow`.

Установщик не пытается импортировать уже активную чужую UFW-конфигурацию. Если
UFW активен, имеются latent rules или работает firewalld, сначала настройте
firewall сами и используйте явное подтверждение:

```bash
sudo bash install.sh --external-firewall
```

В этом режиме необходимо самостоятельно разрешить выбранный Hysteria2 UDP port
публично и выбранный Node API TCP port только с IP Panel (по умолчанию это
`10443/udp` и `2222/tcp`). Provider-level firewall всегда настраивается отдельно
по тем же правилам.

После первой управляемой установки сохраняется hash всех значимых UFW policy
files и системной части эффективного iptables/nftables ruleset. Таблицы
`iptables-nft` учитываются один раз через нормализованный `iptables-save`, а
native nftables policy контролируется отдельно. Поэтому безопасный
`iptables-restore` не создаёт ложный drift только из-за нового порядка таблиц
или пустых встроенных цепочек. Две точные таблицы приложения — `ip remnanode` и
`ip6 remnanode6` — создаются самой Node, меняются её плагинами и поэтому не
входят в hash системного firewall. Root-only backup также содержит исходные
IPv4/IPv6 restore images и снимки ruleset до UFW, после UFW и после запуска Node.

## Транзакция и откат

До первой управляемой записи скрипт:

1. проверяет владельца существующей установки, контейнера и TCP/UDP портов;
2. показывает план и ждёт `APPLY`;
3. создаёт и побайтно проверяет root-only backup;
4. сохраняет состояние `PREPARED`, затем `APPLYING`.

При обычной ошибке или `Ctrl+C` восстанавливаются точные файлы, UFW state и
предыдущее состояние контейнера (отсутствовал/running/stopped). Ошибка самого
отката возвращает отдельный exit code `70`, оставляет
`ROLLBACK_INCOMPLETE` и блокирует повторный запуск до сверки. Для незавершённой
первой установки v1.0.5–v1.0.9 без прежней ноды используется отдельный
fail-closed recovery:

```bash
sudo bash recover.sh
```

Recovery проверяет root-only backup, показывает план и ждёт слово `RECOVER`.
Перед изменением он сохраняет ещё один снимок текущих файлов и firewall.
Восстановленные IPv4/IPv6 policy сравниваются с защищёнными нормализованными
restore images, а native nftables policy — с независимым hash. При несовпадении
состояние до попытки recovery возвращается, а unresolved marker сохраняется.
Для старого backup v1.0.5, в котором ещё не сохранялись restore images,
допускается только строго известный пустой Docker ruleset. Ожидаемое native-nft
состояние строится из него в одноразовом изолированном network namespace, а не
из текущих правил VPS.

Установленные OS/Docker packages не удаляются при rollback. Сбой питания или
`SIGKILL` может прервать процесс без обработчика; сохранённый `APPLYING` marker
не позволит следующему запуску молча затереть состояние.

Backups содержат прежний root-only `.env`, поэтому каталог
`/opt/remnanode/backups/` нельзя копировать в публичные логи или Git. Удалять
старые backup-каталоги следует только вручную после проверки текущей ноды.

## Проверка

После завершения Node в Panel:

```bash
sudo bash status.sh
```

Команда возвращает ненулевой exit code, если контейнер нестабилен, образ не
совпадает с pin, TCP/UDP listener принадлежит не `remnanode`, Hysteria2 inbound
ещё не слушает порт либо управляемый UFW изменился. `SECRET_KEY` она не читает и
не печатает.

## Поддерживаемые системы

- Ubuntu 24.04 LTS — основной и рекомендуемый вариант;
- Ubuntu 22.04 LTS — поддерживаемый вариант;
- `amd64` и `arm64`.

Node закреплена на Remnawave Node 3.3.2 по OCI digest. Теги `latest` и
автоматическое обновление не используются. Обновление версии — отдельный
reviewed release репозитория.
