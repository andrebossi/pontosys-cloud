-- /etc/fluent-bit/systemd_classify.lua
--
-- Does NOT filter and does NOT aggregate: every journal line passes through whole.
-- It only adds two low-cardinality fields used as labels in Loki:
--
--   unit  -> lowercase unit name ("dotnet-app@api.service"), so the query
--            becomes {unit="..."} instead of {SYSTEMD_UNIT="..."}
--   kind  -> "start" | "stop" | "restart_scheduled" | "oom" | "crash" |
--            "failed" | "kernel" | "app"
--
-- "app" is the default: normal Kestrel/application log. That's what you want
-- to see most of the time. The other values are for isolating lifecycle
-- events in Grafana:
--   {job="apps", kind=~"oom|crash|failed"}

function classify(tag, timestamp, record)
  local unit = record["SYSTEMD_UNIT"]
  local transport = record["TRANSPORT"]

  if unit == nil or unit == "" then
    if transport == "kernel" then
      unit = "kernel"
    else
      unit = "unknown"
    end
  end
  record["unit"] = unit

  local msg = record["MESSAGE"] or ""
  local m = string.lower(msg)
  local kind = "app"

  if string.find(m, "out of memory", 1, true)
     or string.find(m, "oom%-kill")
     or string.find(m, "memorymax") then
    kind = "oom"
  elseif string.find(m, "scheduled restart", 1, true) then
    kind = "restart_scheduled"
  elseif string.find(m, "sigsegv", 1, true)
      or string.find(m, "sigkill", 1, true)
      or string.find(m, "sigabrt", 1, true)
      or string.find(m, "core dumped", 1, true) then
    kind = "crash"
  elseif string.find(m, "failed with result", 1, true)
      or string.find(m, "main process exited", 1, true) then
    kind = "failed"
  elseif string.find(m, "^started ") or string.find(m, " started%.") then
    kind = "start"
  elseif string.find(m, "^stopped ") or string.find(m, "deactivated", 1, true) then
    kind = "stop"
  elseif transport == "kernel" then
    kind = "kernel"
  end

  record["kind"] = kind
  return 1, timestamp, record
end
