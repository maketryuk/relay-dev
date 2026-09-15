# Relay — техническое задание

## 1. Рабочая концепция

**Relay** — нативный workspace manager для macOS, который объединяет в одном интерфейсе:

- проекты;
- терминальные сессии;
- AI CLI-агентов;
- dev-сервисы;
- локальные порты;
- Docker / Docker Compose;
- SSH-подключения;
- долгоживущие процессы через отдельный Session Daemon.

Главная идея продукта: **Project — основная сущность**, а все рабочие процессы существуют внутри проекта.

Relay не должен становиться IDE, редактором кода или отдельным AI-чатом. На первых этапах оно выступает как быстрый нативный слой управления уже существующими инструментами: Claude Code, Codex, shell, dev-серверами, Docker и SSH.

Ключевые ориентиры по продукту и UX:

- Warp — терминальный опыт, чёрная визуальная тема, скорость;
- Orca — работа с агентами и сессиями;
- Granular — project/session/workspace-подход;
- HeroUI и Codex — визуальный язык интерфейса;
- Discord — навигация между проектами;
- Docker Desktop — управление сервисами и контейнерами;
- Termius — быстрый доступ к SSH-хостам.

---

## 2. Основные принципы продукта

### 2.1. Native-first

Приложение должно быть нативным для macOS.

Не использовать:

- Electron;
- Chromium;
- React/Vue runtime;
- web-based shell UI как основу приложения.

Цель — минимальная нагрузка на CPU/RAM в состоянии покоя и хорошая отзывчивость даже при нескольких запущенных проектах.

### 2.2. Project-first

Пользователь сначала выбирает проект, после чего видит его:

- Sessions;
- Services;
- Docker;
- SSH;
- Ports;
- Git-информацию.

Сессии не являются глобальной сущностью верхнего уровня.

### 2.3. Terminal-first agents

Claude Code, Codex и другие агенты не интегрируются через собственный чат приложения.

На первом этапе каждый агент — обычная терминальная сессия с заранее известной командой запуска.

### 2.4. Runtime отдельно от GUI

GUI приложения не должен владеть жизненным циклом терминальных процессов.

Все PTY, агенты и долгоживущие сервисы должны принадлежать отдельному Session Daemon.

Закрытие или перезапуск GUI не должен завершать работающие процессы.

### 2.5. Минимум действий

Типовые операции должны выполняться в один клик:

- запустить Claude;
- создать Shell;
- запустить dev server;
- открыть localhost;
- остановить сервис;
- открыть SSH;
- запустить Docker Compose;
- посмотреть активные порты.

---

# 3. UX и навигация

## 3.1. Общая структура

Основное окно состоит из трёх уровней:

1. Project Rail.
2. Project Sidebar.
3. Main Content Area.

### Project Rail

Узкая вертикальная панель слева, визуально близкая к Discord.

Содержит:

- иконки проектов;
- кнопку добавления проекта;
- глобальные настройки;
- агрегированный runtime-статус на каждой иконке проекта.

Название проекта постоянно не отображается.

Название показывается в tooltip при наведении.

### Project Sidebar

Появляется справа от Project Rail для выбранного проекта.

Содержит секции:

- Sessions;
- Services;
- Docker;
- SSH;
- Project / Git info.

Пользователь должен иметь возможность сворачивать второстепенные секции.

### Main Content Area

Основная область зависит от выбранного ресурса.

Примеры:

- терминал;
- логи сервиса;
- Docker logs;
- SSH terminal;
- список портов;
- overview проекта.

---

# 4. Project Rail

## 4.1. Элемент проекта

Каждый проект отображается компактной иконкой.

В качестве изображения могут использоваться:

- пользовательская иконка;
- автоматически сгенерированные инициалы;
- цветной placeholder.

## 4.2. Runtime-индикатор проекта

На иконке проекта отображается маленький статусный indicator.

Статус агрегируется из всех активных Sessions и Services проекта.

Приоритет статусов:

1. Requires Attention / Waiting for User.
2. Error.
3. Working.
4. Finished.
5. Idle.
6. Offline.

Если хотя бы одна сессия ждёт действия пользователя, весь проект должен показывать состояние Requires Attention независимо от остальных работающих сессий.

Пример:

- Claude #1 — Working;
- Claude #2 — Waiting for User;
- Codex — Finished.

Статус проекта: **Waiting for User**.

Это позволяет понимать состояние всех проектов, не переключаясь между ними.

## 4.3. Context Menu проекта

Для проекта должны быть доступны быстрые действия:

- Open;
- Open in Finder;
- Open in external editor;
- Start default service;
- Stop services;
- Project Settings;
- Remove from workspace.

---

# 5. Project Sidebar

## 5.1. Sessions

Основная секция.

Отображает:

- название сессии;
- тип;
- runtime status;
- indicator активности;
- при необходимости короткое состояние.

Примеры состояний:

- Working;
- Waiting;
- Idle;
- Finished;
- Error;
- Disconnected.

Позже возможно отображение краткого activity summary без обязательной AI-интеграции.

## 5.2. Services

Список долгоживущих процессов проекта.

Примеры:

- Dev;
- API;
- Storybook;
- Worker;
- Mock Server.

Для каждого сервиса:

- status;
- обнаруженный порт;
- Start;
- Stop;
- Restart;
- Logs;
- Open URL;
- Copy URL.

## 5.3. Docker

Если у проекта найден Docker-контекст, показывается соответствующая секция.

Содержит:

- Compose project status;
- контейнеры;
- состояние контейнеров;
- основные действия.

## 5.4. SSH

Список релевантных SSH endpoints.

Может включать:

- глобальные SSH hosts;
- закреплённые для проекта hosts;
- недавно использованные hosts.

## 5.5. Project Info

Компактная информация:

- текущая git branch;
- наличие uncommitted changes;
- ahead / behind;
- root path;
- активные ports.

---

# 6. Универсальная модель Session

Session — универсальная интерактивная терминальная сущность.

Поддерживаемые типы:

- Shell;
- Claude Code;
- Codex;
- Gemini CLI;
- OpenCode;
- SSH;
- Custom CLI.

Все типы должны использовать общую runtime-модель.

Тип Session определяет:

- display name;
- executable / command;
- icon;
- стартовые параметры;
- правила определения статуса;
- рабочую директорию.

## 6.1. Создание Session

При создании новой сессии пользователь выбирает тип.

Быстрые варианты:

- Claude;
- Codex;
- Shell.

Дополнительные:

- Gemini;
- OpenCode;
- Custom CLI.

Сессия запускается в root выбранного проекта, если явно не указано другое.

## 6.2. Session lifecycle

Основные состояния:

- Starting;
- Running;
- Waiting;
- Idle;
- Finished;
- Error;
- Disconnected.

Session может переживать закрытие GUI.

После повторного запуска приложения пользователь должен видеть существующую сессию и иметь возможность продолжить работу с ней.

## 6.3. Session naming

По умолчанию:

- Claude;
- Claude 2;
- Codex;
- Shell.

Пользователь может переименовывать Session.

В будущем имя Session может быть связано с задачей или git worktree.

---

# 7. Определение активности AI-агентов

Для MVP не требуется интеграция с API Claude или Codex.

Статус определяется на уровне терминальной активности.

Необходимо отслеживать:

- появление нового output;
- длительное отсутствие output;
- завершение процесса;
- shell prompt;
- известные CLI-паттерны ожидания ввода;
- exit code.

Целевые пользовательские состояния:

- Working;
- Waiting for User;
- Finished;
- Error;
- Idle.

Архитектура detection layer должна позволять позже добавлять отдельные adapters для:

- Claude Code;
- Codex;
- Gemini;
- других CLI-агентов.

Ошибочная классификация не должна влиять на работоспособность самой Session.

---

# 8. Session Daemon

## 8.1. Назначение

Session Daemon — отдельный фоновый процесс, отвечающий за всё runtime-состояние приложения.

GUI является клиентом daemon.

## 8.2. Daemon отвечает за

- создание PTY;
- PTY lifecycle;
- хранение активных terminal sessions;
- stdin/stdout routing;
- shell processes;
- AI CLI processes;
- запуск Services;
- stop / restart Services;
- Docker commands;
- SSH processes;
- port discovery;
- runtime status;
- process metadata;
- session reconnection;
- event stream для GUI.

## 8.3. Главный принцип

GUI можно закрыть или перезапустить без завершения:

- Claude;
- Codex;
- Shell;
- dev server;
- Storybook;
- SSH;
- других управляемых процессов.

## 8.4. Связь GUI и Daemon

Использовать нативный локальный IPC.

Предпочтительный вариант:

- отдельный LaunchAgent;
- локальный XPC/Mach service либо Unix domain socket как транспорт;
- GUI выступает клиентом.

Конкретный IPC transport должен быть скрыт за отдельным слоем, чтобы его можно было заменить без изменения продуктовой логики.

## 8.5. Reconnect

При запуске GUI:

1. приложение подключается к daemon;
2. получает список проектов с активным runtime;
3. получает активные Sessions;
4. восстанавливает UI;
5. подписывается на новые terminal events;
6. пользователь продолжает с того же состояния.

## 8.6. Terminal history

Daemon должен хранить ограниченный scrollback buffer для каждой Session.

После reconnect пользователь должен видеть недавнюю историю терминала.

История должна иметь лимит, чтобы бесконечный output не приводил к неконтролируемому росту RAM.

---

# 9. Terminal Engine

## 9.1. Требования

Terminal layer должен поддерживать:

- полноценный PTY;
- zsh;
- interactive CLI;
- colors;
- Unicode;
- resize;
- mouse events;
- copy/paste;
- selection;
- hyperlinks;
- ANSI / VT sequences;
- CLI applications;
- Claude Code;
- Codex;
- SSH;
- vim/nvim;
- fzf;
- tmux при необходимости.

## 9.2. Выбранный подход

UI терминала должен быть отделён от PTY lifecycle.

PTY живёт в Session Daemon.

Terminal renderer живёт в GUI.

Для первого production-capable варианта рекомендуется использовать существующий нативный terminal emulator core, а не писать собственный VT parser и renderer.

Приоритет:

1. SwiftTerm как более стабильный и простой старт.
2. libghostty как перспективный высокопроизводительный terminal core после стабилизации integration layer.

TerminalEngine должен быть абстракцией, чтобы реализацию можно было заменить без переписывания Sessions и Daemon.

---

# 10. Services

Service — неинтерактивный или долгоживущий процесс проекта.

Примеры:

- npm run dev;
- pnpm dev;
- bun dev;
- Storybook;
- local API;
- worker;
- watcher;
- custom command.

## 10.1. Service states

- Stopped;
- Starting;
- Running;
- Failed;
- Stopping.

## 10.2. Быстрые действия

Для каждого Service:

- Start;
- Stop;
- Restart;
- Logs;
- Open;
- Copy URL.

## 10.3. Автоопределение URL

Приложение должно пытаться определить локальный URL и порт из:

- stdout;
- listening ports дочернего process tree;
- project configuration.

Пользователь может вручную переопределить URL.

## 10.4. Default Dev Service

Проект может иметь Default Service.

Он должен запускаться одной кнопкой без создания отдельной видимой terminal session.

---

# 11. Ports

## 11.1. Назначение

Показывать listening ports, связанные с выбранным проектом и его process tree.

## 11.2. UI

В интерфейсе должна быть компактная кнопка Ports.

Popover показывает:

- port;
- process;
- service/session;
- URL;
- PID при необходимости.

## 11.3. Действия

Для HTTP-порта:

- Open;
- Copy URL.

Для процесса:

- Reveal owner;
- Show logs;
- Stop / Kill, если процесс управляется приложением.

Не завершать неизвестный внешний process без явного действия пользователя.

---

# 12. Docker

## 12.1. Discovery

При открытии проекта автоматически проверять наличие:

- Dockerfile;
- compose.yaml;
- compose.yml;
- docker-compose.yaml;
- docker-compose.yml.

Также можно использовать Docker CLI для определения уже запущенных контейнеров, относящихся к проекту.

## 12.2. Docker Section

Если Docker доступен, Project Sidebar показывает Docker section.

Необходимо отображать:

- Compose project;
- containers;
- status;
- published ports.

## 12.3. Actions

На уровне Compose:

- Up;
- Down;
- Restart;
- Logs.

На уровне container:

- Start;
- Stop;
- Restart;
- Logs;
- Open exposed port;
- Copy container name / id.

## 12.4. Ограничения

Не требуется реализовывать полноценную замену Docker Desktop.

Не нужны:

- image registry;
- build history UI;
- volume explorer;
- network management;
- Kubernetes.

Цель — управление Docker-контекстом текущего проекта.

## 12.5. Docker dependency

Использовать установленный пользователем Docker-compatible CLI/runtime.

Приложение не должно поставлять собственный Docker Engine.

В будущем возможно добавить поддержку альтернативных runtime:

- OrbStack;
- Colima;
- Rancher Desktop.

---

# 13. SSH

## 13.1. Источник данных

Приложение должно автоматически читать стандартную конфигурацию OpenSSH пользователя.

Основной источник:

- ~/.ssh/config.

Необходимо учитывать Include-директивы.

## 13.2. Что отображать

Для каждого Host:

- alias;
- HostName;
- User;
- Port;
- IdentityFile при наличии.

## 13.3. Безопасность

Приложение не должно копировать или импортировать приватные SSH-ключи в собственное хранилище.

Используются системные OpenSSH и ssh-agent.

Пароли не должны сохраняться приложением в plaintext.

## 13.4. SSH Session

Нажатие на host создаёт стандартную Session типа SSH.

Она работает через тот же PTY/Daemon слой.

## 13.5. Project SSH Pins

Пользователь может закрепить определённые SSH Hosts за конкретным проектом.

Например:

- staging;
- production;
- database;
- bastion.

Закреплённые Hosts показываются первыми в SSH section проекта.

---

# 14. Project Discovery и Configuration

## 14.1. Добавление проекта

Основной способ:

- выбрать локальную директорию.

Проект должен сохраняться в workspace приложения.

## 14.2. Автоматически определять

По возможности:

- git repository;
- package manager;
- package.json scripts;
- Docker;
- Compose;
- текущую branch;
- стандартную dev command;
- project name.

## 14.3. Project Settings

Настройки проекта:

- display name;
- icon;
- root path;
- default shell;
- default agent;
- default Service;
- service definitions;
- preferred editor;
- SSH pins;
- Docker integration;
- environment options.

---

# 15. Git

Git не является полноценным UI-модулем в MVP.

Необходимо только базовое состояние:

- current branch;
- dirty / clean;
- ahead;
- behind.

Действия уровня commit / rebase / merge могут быть добавлены позже.

Архитектура должна учитывать будущую сущность Workspace, основанную на git worktree.

---

# 16. Workspaces и Git Worktrees — v0.2

В следующей версии между Project и Session появляется Workspace.

Структура:

Project → Workspace → Sessions / Services / Ports.

Примеры Workspace:

- main;
- BOTICA-183;
- BOTICA-184.

Workspace может быть связан с отдельным git worktree.

Для каждого Workspace:

- отдельная рабочая директория;
- branch;
- Sessions;
- Services;
- ports.

## 16.1. Automatic ports

Разные worktrees одного проекта не должны конфликтовать по стандартному dev port.

Приложение должно уметь:

- найти свободный port;
- запустить Service на нём;
- сохранить привязку;
- показывать его рядом с Workspace.

---

# 17. Notifications

macOS notifications используются только для событий, которые действительно требуют внимания.

Основные события:

- агент ждёт пользователя;
- agent/session finished;
- agent/session failed;
- service failed;
- Docker startup failed.

Не уведомлять о каждом terminal output event.

Пользователь должен иметь возможность отключить notifications:

- глобально;
- для проекта;
- по типу события.

---

# 18. UI / Visual System

## 18.1. Общий стиль

Собственный нативный UI-kit.

Визуальные ориентиры:

- HeroUI;
- Codex;
- Warp.

Не копировать компоненты напрямую.

## 18.2. Theme

Основная тема — очень тёмная / почти чёрная.

Характер:

- pure/near-black background;
- слегка отличающиеся layered surfaces;
- мягкие borders;
- большие аккуратные radius;
- минимальное количество акцентных цветов;
- высокая контрастность terminal content;
- спокойные hover states.

## 18.3. Цвет используется прежде всего для статусов

Например:

- Working;
- Waiting;
- Error;
- Success / Finished;
- Offline.

Основной UI не должен выглядеть разноцветным.

## 18.4. Собственный UI Kit

Минимальный набор компонентов:

- Button;
- IconButton;
- Input;
- Search;
- Tooltip;
- Popover;
- Menu;
- ContextMenu;
- Badge;
- StatusDot;
- Divider;
- Tabs;
- SidebarItem;
- ProjectIcon;
- ScrollContainer;
- Modal / Sheet;
- Command Palette.

---

# 19. Command Palette

Глобальная Command Palette должна позволять выполнять основные действия с клавиатуры.

Примеры:

- Switch Project;
- New Claude Session;
- New Codex Session;
- New Shell;
- Start Dev;
- Restart Dev;
- Open Port;
- Connect SSH;
- Open Project in Finder;
- Project Settings.

Command Palette не должна зависеть от AI.

---

# 20. Keyboard-first UX

Приложение ориентировано на разработчиков, поэтому все основные операции должны иметь shortcuts.

Необходимо предусмотреть:

- переключение проектов;
- переключение Sessions;
- создание Session;
- закрытие Session;
- Command Palette;
- focus terminal;
- next / previous Session;
- запуск Default Service.

Конкретная раскладка горячих клавиш определяется позже.

---

# 21. Persistence

На диске сохраняются:

- проекты;
- project settings;
- service definitions;
- custom Session types;
- pinned SSH hosts;
- UI state;
- last active Project;
- last active Session;
- metadata Sessions;
- runtime identifiers daemon.

Не хранить plaintext secrets.

Для простого локального persistence предпочтительно использовать SwiftData либо SQLite-backed storage.

Runtime state является источником истины в Session Daemon, а persistent storage — источником конфигурации.

---

# 22. Security

Основные правила:

- не сохранять приватные SSH keys;
- не сохранять shell passwords;
- не логировать secrets из environment;
- не отправлять данные во внешние сервисы без явной функции;
- приложение должно работать полностью локально;
- telemetry по умолчанию отсутствует либо строго opt-in;
- sensitive values при необходимости хранить в macOS Keychain.

---

# 23. Архитектура приложения

Высокоуровневые компоненты:

## GUI Application

Отвечает за:

- Project Rail;
- Project Sidebar;
- Terminal renderer;
- logs UI;
- Docker UI;
- SSH UI;
- Ports UI;
- Settings;
- notifications presentation.

## Session Daemon

Отвечает за:

- PTY;
- processes;
- Sessions;
- Services;
- SSH;
- Docker CLI;
- ports;
- runtime statuses;
- scrollback;
- process lifecycle.

## Persistence Layer

Отвечает за:

- project configuration;
- user settings;
- custom commands;
- pins;
- UI preferences.

## Integration Layer

Отдельные adapters:

- Git;
- Docker;
- OpenSSH;
- Claude CLI;
- Codex CLI;
- Gemini CLI;
- generic CLI.

## Terminal Engine Layer

Отдельная abstraction между GUI и конкретным terminal renderer.

---

# 24. Рекомендуемый стек

## Язык

Swift 6.

## UI

SwiftUI.

AppKit использовать там, где SwiftUI ограничивает:

- terminal hosting;
- advanced focus handling;
- keyboard events;
- window behavior;
- context menus при необходимости.

## Terminal

Для первой версии:

- SwiftTerm.

Архитектура terminal layer должна позволять позже перейти на:

- libghostty.

## Runtime / PTY

Нативные macOS / Darwin process и PTY APIs внутри Session Daemon.

Не привязывать PTY lifecycle к GUI.

## Background service

Отдельный Session Daemon через launchd / LaunchAgent.

Регистрация и lifecycle должны использовать рекомендуемый macOS механизм для helper/background service.

## IPC

Нативный local IPC.

Предпочтительно:

- XPC/Mach service;

либо:

- Unix domain socket,

если это значительно упрощает reconnect и event streaming.

IPC должен поддерживать:

- commands;
- request/response;
- continuous terminal stream;
- runtime events.

## Persistence

SwiftData или SQLite.

Для первой версии предпочтительнее SwiftData, если он не мешает будущей миграции.

## Git

Системный git CLI.

## Docker

Системный docker CLI и docker compose.

## SSH

Системный OpenSSH client и ~/.ssh/config.

## Notifications

UserNotifications framework.

## Secrets

macOS Keychain.

---

# 25. Performance Goals

Приложение должно ощущаться как лёгкая системная developer utility.

Цели:

- минимальное CPU usage в idle;
- отсутствие постоянного polling с высокой частотой;
- event-driven runtime по возможности;
- ограниченные terminal scrollback buffers;
- lazy rendering неактивных terminal views;
- не держать тяжёлый terminal renderer активным для невидимых Sessions;
- не перерисовывать Project Rail при каждом terminal event;
- Docker/ports/git discovery выполнять с разумным debounce/cache.

Project status должен вычисляться из уже известных runtime events, а не через постоянный полный process scan.

---

# 26. MVP v0.1

Обязательный scope:

### Projects

- Add local project;
- Remove project;
- Project Rail;
- Project Settings;
- project status indicator.

### Sessions

- Shell;
- Claude Code;
- Codex;
- Custom CLI;
- multiple Sessions per project;
- rename;
- close/terminate;
- terminal history;
- reconnect.

### Session Daemon

- persistent PTY;
- process lifecycle;
- GUI reconnect;
- terminal event stream.

### Services

- custom Service;
- start;
- stop;
- restart;
- logs;
- port detection;
- open localhost.

### Ports

- project-related listening ports;
- open;
- copy URL;
- process ownership.

### Docker

- Compose discovery;
- Up;
- Down;
- Restart;
- container status;
- logs;
- exposed ports.

### SSH

- parse ~/.ssh/config;
- Include support;
- list hosts;
- connect;
- pin host to Project.

### Statuses

- Working;
- Waiting;
- Finished;
- Error;
- Idle;
- project-level aggregation.

### UI

- native dark UI;
- Project Rail;
- Project Sidebar;
- Main Content;
- Command Palette;
- keyboard navigation.

---

# 27. v0.2

Основные функции следующего этапа:

- Workspaces;
- git worktrees;
- workspace-specific Sessions;
- workspace-specific Services;
- automatic dev ports;
- session templates;
- project templates;
- richer Claude/Codex status adapters;
- diff preview;
- Git actions;
- activity history.

---

# 28. v0.3+

Возможное развитие:

- Boss / Worker orchestration;
- создание worker Session из основной Session;
- task graph;
- automatic worktrees per agent;
- agent completion notifications;
- diff review;
- merge workflow;
- MCP management;
- project context;
- local agent API integrations;
- optional own chat layer.

Эти функции не должны влиять на архитектуру MVP и не являются обязательными для первой версии.

---

# 29. Non-goals

На первых этапах приложение НЕ является:

- IDE;
- code editor;
- Cursor replacement;
- Docker Desktop replacement;
- Termius replacement;
- Git GUI;
- AI chat app;
- cloud workspace;
- remote development platform.

Не реализовывать без необходимости:

- собственный VT terminal emulator;
- собственный SSH protocol implementation;
- собственный Docker Engine;
- собственный Git implementation;
- облачную синхронизацию;
- аккаунты;
- командные workspace;
- billing.

Главная задача — качественно объединить уже существующие CLI-инструменты в единый native macOS workflow.

---

# 30. Acceptance Criteria v0.1

MVP считается успешным, если пользователь может:

1. Добавить несколько локальных проектов.
2. Переключаться между ними через левый Project Rail.
3. Создать несколько Claude/Codex/Shell Sessions внутри одного проекта.
4. Запустить Sessions одновременно в разных проектах.
5. Закрыть GUI и открыть его снова без завершения работающих Sessions.
6. Продолжить взаимодействовать с восстановленной Session.
7. Видеть на иконке проекта, если агент:
   - работает;
   - ждёт пользователя;
   - завершился;
   - упал.
8. Запустить dev server одной кнопкой.
9. Увидеть автоматически определённый localhost port.
10. Открыть localhost одним действием.
11. Просмотреть и перезапустить Service.
12. Обнаружить Docker Compose в проекте и запустить его.
13. Просмотреть контейнеры и их состояние.
14. Прочитать SSH hosts из ~/.ssh/config.
15. Открыть SSH Session одним действием.
16. Использовать несколько проектов одновременно без заметной нагрузки от самого GUI.
17. Работать с приложением преимущественно с клавиатуры.

---

# 31. Главный продуктовый критерий

Приложение должно снижать количество ручных действий между моментом:

**«я хочу поработать над проектом»**

и состоянием:

**«агенты, dev server, Docker и нужные SSH-сессии уже запущены и видны в одном месте».**

При наличии нескольких проектов пользователь должен за один взгляд понимать:

- где сейчас что-то работает;
- где агент ждёт его ответа;
- где работа закончена;
- какие dev-сервисы подняты;
- на каких портах они доступны.

Именно это является основной ценностью продукта.
