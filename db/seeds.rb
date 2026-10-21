# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

# The posts bin/ractor-test requests. It runs db:seed in a separate process, so
# its own process never uses Post before the application is ractorized.
Post.delete_all
Post.create!(body: "Seed post body from Ractor test")
Post.create!(body: "Delete me from Ractor test")
