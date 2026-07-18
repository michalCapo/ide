local M = {}

function M.system(args, opts)
  opts = vim.tbl_extend("force", { text = true }, opts or {})
  local allowed = opts.allowed_codes or { 0 }
  opts.allowed_codes = nil
  local result = vim.system(args, opts):wait()
  for _, code in ipairs(allowed) do
    if result.code == code then return result.stdout or "", nil, result end
  end
  local message = vim.trim(result.stderr or result.stdout or "")
  return nil, message ~= "" and message or table.concat(args, " ") .. " failed", result
end

function M.root(cwd)
  local out, err = M.system({ "git", "-C", cwd or vim.uv.cwd(), "rev-parse", "--show-toplevel" })
  return out and vim.trim(out) or nil, err
end

function M.git(root, args, opts)
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  return M.system(command, opts)
end

function M.git_async(root, args, callback)
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  return vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      callback(result.code == 0, result.stdout or "", vim.trim(result.stderr or ""), result)
    end)
  end)
end

function M.split_nul(text)
  local result, start = {}, 1
  while start <= #(text or "") do
    local stop = text:find("\0", start, true)
    if not stop then break end
    result[#result + 1] = text:sub(start, stop - 1)
    start = stop + 1
  end
  return result
end

function M.parse_status(text)
  local result, items, i = {}, M.split_nul(text), 1
  while i <= #items do
    local entry, old_path = items[i], nil
    local status, path = entry:sub(1, 2), entry:sub(4)
    if status:find("R", 1, true) or status:find("C", 1, true) then
      i = i + 1
      old_path = items[i]
    end
    if path ~= "" then
      result[#result + 1] = { kind = "file", path = path, old_path = old_path, status = status,
        staged = status:sub(1, 1) ~= " " and status:sub(1, 1) ~= "?",
        unstaged = status:sub(2, 2) ~= " ", conflict = status:find("U", 1, true) ~= nil }
    end
    i = i + 1
  end
  table.sort(result, function(a, b) return a.path < b.path end)
  return result
end

function M.status(root)
  local out, err = M.git(root, { "status", "--porcelain=v1", "-z", "--untracked-files=all" })
  return out and M.parse_status(out) or nil, err
end

function M.tree(files, collapsed)
  local root = { kind = "folder", path = "", children = {} }
  for _, file in ipairs(files) do
    local node, prefix = root, ""
    local parts = vim.split(file.path, "/", { plain = true })
    for index = 1, #parts - 1 do
      prefix = prefix == "" and parts[index] or prefix .. "/" .. parts[index]
      local child = node.children[prefix]
      if not child then
        child = { kind = "folder", path = prefix, name = parts[index], children = {} }
        node.children[prefix] = child
      end
      node = child
    end
    node.children[file.path] = file
  end
  local rows = {}
  local function visit(node, depth)
    local children = {}
    for _, child in pairs(node.children or {}) do children[#children + 1] = child end
    table.sort(children, function(a, b)
      if a.kind ~= b.kind then return a.kind == "folder" end
      return a.path < b.path
    end)
    for _, child in ipairs(children) do
      child.depth = depth
      rows[#rows + 1] = child
      if child.kind == "folder" and not collapsed[child.path] then visit(child, depth + 1) end
    end
  end
  visit(root, 0)
  return rows
end

function M.parse_refs(text)
  local refs = {}
  for line in (text or ""):gmatch("[^\n]+") do
    local name, oid, upstream, head = line:match("^(.-)%z(.-)%z(.-)%z(.-)$")
    if name then refs[#refs + 1] = { name = name, oid = oid, upstream = upstream, current = head == "*" } end
  end
  return refs
end

function M.refs(root, remote)
  local format = "%(refname:short)%00%(objectname)%00%(upstream:short)%00%(HEAD)"
  local prefix = remote and "refs/remotes" or "refs/heads"
  local out, err = M.git(root, { "for-each-ref", "--format=" .. format, "--sort=refname", prefix })
  return out and M.parse_refs(out) or nil, err
end


function M.commits(root, ref, limit)
  local out, err = M.git(root, { "log", "--date=short", "--format=%H%x00%h%x00%ad%x00%an%x00%s", "--max-count=" .. (limit or 200), ref })
  if not out then return nil, err end
  local commits = {}
  for line in out:gmatch("[^\n]+") do
    local oid, short, date, author, subject = line:match("^(.-)%z(.-)%z(.-)%z(.-)%z(.*)$")
    if oid then commits[#commits + 1] = { oid = oid, short = short, date = date, author = author, subject = subject } end
  end
  return commits
end

function M.stashes(root)
  local out, err = M.git(root, { "stash", "list", "--format=%gd%x00%H%x00%gs" })
  if not out then return nil, err end
  local stashes = {}
  for line in out:gmatch("[^\n]+") do
    local ref, oid, subject = line:match("^(.-)%z(.-)%z(.*)$")
    if ref then stashes[#stashes + 1] = { ref = ref, oid = oid, subject = subject } end
  end
  return stashes
end

function M.changed_paths(root, revision)
  local args = revision and { "diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-z", revision }
    or { "status", "--porcelain=v1", "-z", "--untracked-files=all" }
  local out, err = M.git(root, args)
  if not out then return nil, err end
  if not revision then return M.parse_status(out) end
  local items, result, i = M.split_nul(out), {}, 1
  while i <= #items do
    local status = items[i]
    i = i + 1
    local old_path, path
    if status and status:match("^[RC]") then
      old_path, path = items[i], items[i + 1]
      i = i + 2
    else
      path = items[i]
      i = i + 1
    end
    if status and path then
      result[#result + 1] = { kind = "file", path = path, old_path = old_path, status = status }
    end
  end
  return result
end

function M.diff_text(root, revision, path)
  local parents, err = M.git(root, { "rev-list", "--parents", "-n", "1", revision })
  if not parents then return nil, err end
  local words = vim.split(vim.trim(parents), "%s+")
  local parent = words[2]
  if not parent then
    parent, err = M.git(root, { "hash-object", "-t", "tree", "/dev/null" })
    if not parent then return nil, err end
    parent = vim.trim(parent)
  end
  return M.git(root, { "diff", parent, revision, "--", path })
end

return M
