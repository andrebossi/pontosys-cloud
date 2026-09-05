output "databases" { value = [for database in mysql_database.this : database.name] }

output "app_usernames" {
  value = { for key, user in mysql_user.app : key => "${user.user}@${user.host}" }
}
