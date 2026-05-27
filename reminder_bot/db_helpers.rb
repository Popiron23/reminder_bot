require_relative "database"

# Найти или создать пользователя по telegram_id
def find_or_create_user(telegram_id, username)
  DB[:users].where(telegram_id: telegram_id).first ||
    begin
      id = DB[:users].insert(telegram_id: telegram_id, username: username)
      DB[:users].where(id: id).first
    end
end

# Создать напоминание, возвращает id новой записи
def create_reminder(user_id, remind_at, text)
  DB[:reminders].insert(user_id: user_id, remind_at: remind_at, text: text)
end

# Список активных (ещё не отправленных) напоминаний пользователя
def user_reminders(user_id)
  DB[:reminders]
    .where(user_id: user_id, fired: false)
    .where { remind_at > Time.now }
    .order(:remind_at)
    .all
end

# Пометить напоминание как выполненное
def mark_fired(reminder_id)
  DB[:reminders].where(id: reminder_id).update(fired: true)
end

# Удалить напоминание по порядковому номеру в списке пользователя
# Возвращает true если удалено, false если не найдено
def delete_reminder(user_id, index)
  list = user_reminders(user_id)
  reminder = list[index - 1]
  return false unless reminder

  DB[:reminders].where(id: reminder[:id]).delete
  true
end

# Все активные напоминания (для восстановления после перезапуска)
def all_pending_reminders
  DB[:reminders]
    .join(:users, id: :user_id)
    .where(fired: false)
    .where { remind_at > Time.now }
    .select(
      Sequel[:reminders][:id],
      Sequel[:reminders][:remind_at],
      Sequel[:reminders][:text],
      Sequel[:users][:telegram_id]
    )
    .all
end
