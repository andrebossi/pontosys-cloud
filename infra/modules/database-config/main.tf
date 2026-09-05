provider "mysql" {
  endpoint = "${coalesce(var.db_host, "127.0.0.1")}:${var.db_port}"
  username = var.admin_username
  password = var.admin_password
  tls      = var.db_tls
}

locals {
  db_apps = var.manage_databases ? var.applications : {}

  app_databases = merge([
    for key, app in local.db_apps : {
      for database in coalescelist(lookup(app, "databases", []), [app.db_name]) :
      "${key}/${database}" => { app = key, database = database }
    }
  ]...)

  databases = toset([for key, item in local.app_databases : item.database])
}

resource "mysql_database" "this" {
  for_each = local.databases

  name                  = each.key
  default_character_set = var.database_character_set
  default_collation     = var.database_collation
}

resource "mysql_user" "app" {
  for_each = local.db_apps

  user               = each.value.db_user
  host               = lookup(each.value, "db_host", "%")
  plaintext_password = var.app_passwords[each.key]
}

resource "mysql_grant" "app" {
  for_each = local.app_databases

  user       = mysql_user.app[each.value.app].user
  host       = mysql_user.app[each.value.app].host
  database   = mysql_database.this[each.value.database].name
  privileges = lookup(local.db_apps[each.value.app], "grants", var.default_grants)
}
