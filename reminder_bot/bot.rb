ENV["TZ"] = "Europe/Moscow"
require "telegram/bot"
require "rufus-scheduler"
require_relative "database"
require_relative "db_helpers"

TOKEN = ENV.fetch("TELEGRAM_TOKEN") { raise "Укажи TELEGRAM_TOKEN в переменных окружения!" }

scheduler = Rufus::Scheduler.new

# Состояния диалога в памяти: { telegram_id => { step:, dt: } }
states = {}

# Восстановить все незакрытые напоминания из БД в планировщик
def reschedule_pending(scheduler, bot)
  pending = all_pending_reminders
  puts "⏳ Восстанавливаем #{pending.size} напоминаний из БД..."

  pending.each do |r|
    scheduler.at(r[:remind_at]) do
      bot.api.send_message(chat_id: r[:telegram_id], text: "🔔 Напоминание!\n\n#{r[:text]}")
      mark_fired(r[:id])
    end
  end
end

Telegram::Bot::Client.run(TOKEN) do |bot|
  reschedule_pending(scheduler, bot)
  puts "✅ Бот запущен и слушает сообщения..."

  bot.listen do |message|
    next unless message.is_a?(Telegram::Bot::Types::Message)
    next unless message.text

    user_id  = message.from.id
    username = message.from.username.to_s
    text     = message.text.strip
    state    = states[user_id]

    # Найти или создать пользователя в БД при каждом сообщении
    db_user = find_or_create_user(user_id, username)

    case text

    # ── /start ──────────────────────────────────────────────────────────────
    when "/start"
      states.delete(user_id)
      bot.api.send_message(
        chat_id: user_id,
        text: "👋 Привет! Я бот-напоминалка.\n\n" \
              "📌 Команды:\n" \
              "/remind — создать напоминание\n" \
              "/list   — список напоминаний\n" \
              "/delete N — удалить напоминание №N\n" \
              "/cancel — отменить текущее действие"
      )

    # ── /remind ──────────────────────────────────────────────────────────────
    when "/remind"
      states[user_id] = { step: :waiting_time }
      bot.api.send_message(
        chat_id: user_id,
        text: "🕐 Введи дату и время напоминания в формате:\n" \
              "ДД.ММ.ГГГГ ЧЧ:ММ\n\n" \
              "Например: #{(Time.now + 3600).strftime("%d.%m.%Y %H:%M")}"
      )

    # ── /list ────────────────────────────────────────────────────────────────
    when "/list"
      list = user_reminders(db_user[:id])

      if list.empty?
        bot.api.send_message(chat_id: user_id, text: "📭 У тебя нет активных напоминаний.")
      else
        lines = list.each_with_index.map do |r, i|
          "#{i + 1}. 📅 #{r[:remind_at].strftime("%d.%m.%Y %H:%M")} — #{r[:text]}"
        end
        bot.api.send_message(
          chat_id: user_id,
          text: "📋 Активные напоминания (#{list.size}):\n\n#{lines.join("\n")}"
        )
      end

    # ── /delete N ────────────────────────────────────────────────────────────
    when /^\/delete (\d+)$/
      index = $1.to_i
      if delete_reminder(db_user[:id], index)
        bot.api.send_message(chat_id: user_id, text: "🗑 Напоминание №#{index} удалено.")
      else
        bot.api.send_message(chat_id: user_id, text: "❌ Напоминание №#{index} не найдено.")
      end

    # ── /cancel ───────────────────────────────────────────────────────────────
    when "/cancel"
      if states.key?(user_id)
        states.delete(user_id)
        bot.api.send_message(chat_id: user_id, text: "❌ Действие отменено.")
      else
        bot.api.send_message(chat_id: user_id, text: "Нечего отменять.")
      end

    # ── Обработка диалога ────────────────────────────────────────────────────
    else
      if state.nil?
        bot.api.send_message(
          chat_id: user_id,
          text: "Не понимаю команду. Используй /remind чтобы создать напоминание."
        )
        next
      end

      case state[:step]

      # Шаг 1: ожидаем дату и время
      when :waiting_time
        begin
          dt = Time.strptime(text, "%d.%m.%Y %H:%M")
          raise ArgumentError, "past time" if dt <= Time.now

          states[user_id][:dt]   = dt
          states[user_id][:step] = :waiting_text

          bot.api.send_message(chat_id: user_id, text: "✏️ Теперь напиши текст напоминания:")
        rescue ArgumentError
          bot.api.send_message(
            chat_id: user_id,
            text: "❌ Неверный формат или прошедшее время.\n" \
                  "Попробуй: #{(Time.now + 3600).strftime("%d.%m.%Y %H:%M")}"
          )
        end

      # Шаг 2: ожидаем текст напоминания
      when :waiting_text
        dt          = state[:dt]
        remind_text = text

        # Сохраняем в SQLite
        reminder_id = create_reminder(db_user[:id], dt, remind_text)

        # Планируем отправку
        scheduler.at(dt) do
          bot.api.send_message(chat_id: user_id, text: "🔔 Напоминание!\n\n#{remind_text}")
          mark_fired(reminder_id)
        end

        states.delete(user_id)

        bot.api.send_message(
          chat_id: user_id,
          text: "✅ Напоминание создано!\n" \
                "📅 #{dt.strftime("%d.%m.%Y в %H:%M")}\n" \
                "📝 #{remind_text}"
        )
      end
    end

  rescue StandardError => e
    puts "❗ Ошибка при обработке сообщения: #{e.class}: #{e.message}"
    puts e.backtrace.first(5).join("\n")
  end
end
