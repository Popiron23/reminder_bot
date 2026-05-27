require "sequel"

DB = Sequel.connect("sqlite:///app/data/reminders.db")

DB.create_table? :users do
  primary_key :id
  Integer     :telegram_id, unique: true, null: false
  String      :username
  DateTime    :created_at,  default: Sequel::CURRENT_TIMESTAMP
end

DB.create_table? :reminders do
  primary_key :id
  foreign_key :user_id,   :users, null: false
  DateTime    :remind_at, null: false
  String      :text,      null: false
  TrueClass   :fired,     default: false
  DateTime    :created_at, default: Sequel::CURRENT_TIMESTAMP
end
