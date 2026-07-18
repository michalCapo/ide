local git = require("views.git")

local status = table.concat({
  " M ordinary file.txt\0",
  "R  renamed.txt\0old name.txt\0",
  "?? dir/new file.txt\0",
})
local files = git.parse_status(status)
assert(#files == 3)
assert(files[1].path == "dir/new file.txt" and files[1].unstaged)
assert(files[3].path == "renamed.txt" and files[3].old_path == "old name.txt" and files[3].staged)

local rows = git.tree(files, {})
assert(rows[1].kind == "folder" and rows[1].path == "dir")
assert(rows[2].path == "dir/new file.txt")
local collapsed = git.tree(files, { dir = true })
assert(#collapsed == 3)

local refs = git.parse_refs("main\0abc\0origin/main\0*\nfeature\0def\0\0 \n")
assert(#refs == 2 and refs[1].current and refs[1].upstream == "origin/main")

local test_root = vim.fn.tempname()
vim.fn.mkdir(test_root, "p")
local function command(args)
  local result = vim.system(args, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
command({ "git", "-C", test_root, "init", "-q" })
command({ "git", "-C", test_root, "config", "user.email", "test@example.com" })
command({ "git", "-C", test_root, "config", "user.name", "Test" })
vim.fn.writefile({ "one" }, test_root .. "/one.txt")
command({ "git", "-C", test_root, "add", "one.txt" })
command({ "git", "-C", test_root, "commit", "-qm", "initial" })
local commit_files, commit_err = git.changed_paths(test_root, "HEAD")
assert(commit_files, commit_err)
assert(#commit_files == 1 and commit_files[1].path == "one.txt" and commit_files[1].status == "A")
vim.fn.delete(test_root, "rf")

print("lazyrepo parser tests: ok")
