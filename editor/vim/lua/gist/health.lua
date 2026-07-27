-- :checkhealth gist — Neovim's renderer over the one report.
--
-- The findings themselves live in autoload/gist/health.vim so that plain Vim
-- (:GistHealth) and Neovim can never disagree about whether gist is wired up.

local M = {}

function M.check()
  local health = vim.health or require('health')
  health.start('gist')

  local ok, rows = pcall(vim.fn['gist#health#report'])
  if not ok then
    health.error('gist plugin is not loaded', { tostring(rows) })
    return
  end

  local report = {
    ok = health.ok,
    warn = health.warn,
    error = health.error,
    info = health.info,
  }
  for _, row in ipairs(rows) do
    local emit = report[row.level] or health.info
    local advice = row.advice ~= '' and { row.advice } or nil
    emit(row.msg, advice)
  end
end

return M
