# The primary database holds nothing but the table the test jobs write to.
ActiveRecord::Schema[7.1].define(version: 1) do
  create_table "job_results", force: :cascade do |t|
    t.string "queue_name"
    t.string "status"
    t.string "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end
end
