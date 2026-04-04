-- Ensure help tags are generated for this plugin once the doc file exists.
do
  local ok, info = pcall(debug.getinfo, 1, 'S')
  if not ok or not info or type(info.source) ~= 'string' then
    -- fall through: commands will still be registered
  else
    local source = info.source
    if source:sub(1, 1) == '@' and vim and vim.fn and vim.fn.fnamemodify then
      local plugin_dir = vim.fn.fnamemodify(source:sub(2), ':p:h:h')
      local doc_dir = plugin_dir .. '/doc'
      if vim.fn.isdirectory(doc_dir) == 1 and vim.fn.filereadable(doc_dir .. '/gbc.txt') == 1 then
        local tags_path = doc_dir .. '/tags'
        if vim.fn.filereadable(tags_path) ~= 1 then
          pcall(vim.cmd.helptags, doc_dir)
        end
      end
    end
  end
end

require('gbc')._register_commands()
