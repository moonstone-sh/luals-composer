--[[
  luals-composer / merge

  Pure diff-merging logic. No I/O, no globals, no LuaLS dependency — so it is
  unit-testable in isolation (see tests/merge_spec.lua).

  WHAT A DIFF IS
  --------------
  LuaLS's `OnSetText` may return a `string.merger.diff[]`, defined in
  `script/string-merger.lua:1-4` as `{ start, finish, text }` where `start` and
  `finish` are 1-based **byte offsets into the ORIGINAL text**. `mergeDiff`
  (`string-merger.lua:51-76`) applies them:

      table.sort(info, function(a, b) return a.start < b.start end)
      cur = 1
      for _, diff in ipairs(info) do
          buf[#buf+1] = text:sub(cur, diff.start - 1)
          buf[#buf+1] = diff.text
          cur = diff.finish + 1
      end
      buf[#buf+1] = text:sub(cur)

  Two consequences drive everything below.

  1. Offsets are into the ORIGINAL text, never into a partially-rewritten one.
     So N plugins can each be handed the SAME unmodified text and their diffs
     concatenated — no chaining, no offset rebasing.

  2. `cur` only ever moves to `diff.finish + 1`. If a later hunk's `start` is
     less than the current `cur`, `cur` moves BACKWARD and the bytes in between
     get emitted a second time. That is silent duplication, not an error. This
     is the corruption mode the design doc reproduced as `Redefined local Cfg`.

  A hunk is an INSERTION when it consumes no original bytes (`finish < start`,
  canonically `finish == start - 1`): `cur` is set to `start`, so it advances
  nothing and can never conflict with another insertion. A hunk is a
  REPLACEMENT when `finish >= start`.

  THE INVARIANT WE GUARANTEE
  --------------------------
  `mergeDiff`'s `table.sort` is NOT stable, so we cannot rely on the relative
  order of two hunks that share a `start`. Rather than hope, this module emits
  a canonical list in which every hunk has a DISTINCT `start` and each hunk's
  `start` is strictly greater than the previous hunk's `finish`. Under that
  invariant the sort has exactly one possible outcome and `cur` is strictly
  monotonic, so the merged text is deterministic and correct no matter how
  LuaLS orders things internally.

  Reaching it takes three steps: normalise (§normalise), resolve conflicts by
  plugin priority (§resolve), then coalesce same-offset hunks into one
  (§coalesce).
--]]

local M = {}

--- A hunk consumes no original bytes.
---@param h table
---@return boolean
function M.is_insertion(h)
  return h.finish < h.start
end

--- Canonical zero-width form for an insertion at `pos`.
---@param pos integer
---@param text string
---@return table
function M.insertion(pos, text)
  return { start = pos, finish = pos - 1, text = text }
end

--------------------------------------------------------------------------
-- normalise
--------------------------------------------------------------------------

--- Turn one plugin's raw `OnSetText` return value into a plain array of
--- validated hunks.
---
--- Accepts the three shapes real plugins in this ecosystem return:
---   * `nil`      — "not my file" (valua, hydronium-luax on `.lua`)
---   * a `string` — whole-file rewrite, the `legacy` edit mode. Such a plugin
---                  typically returns the text VERBATIM when it has nothing to
---                  say, which we detect and treat as nil. (clingy did exactly
---                  this until v0.6.1; it now returns insertion diffs.)
---   * a table    — a diff array, possibly with extra non-array fields such as
---                  hydronium-luax's vestigial `diffs.text`
---
---@param result any        raw return value from a child's OnSetText
---@param text string       the ORIGINAL document text
---@param owner string      child plugin name, for diagnostics
---@return table hunks
---@return table warnings   array of human-readable strings
function M.normalise(result, text, owner)
  local hunks, warnings = {}, {}
  local n = #text

  if result == nil then
    return hunks, warnings
  end

  if type(result) == 'string' then
    -- A plugin that returns the input unchanged is saying "no change".
    -- clingy's `process_text` did exactly this on every early-out (it now
    -- returns insertion diffs from OnSetText instead), and any other `legacy`
    -- string-returning child can too. Without this check, every file such a
    -- plugin did not care about would still claim the whole document and
    -- starve every other plugin.
    if result == text then
      return hunks, warnings
    end
    hunks[1] = { start = 1, finish = n, text = result }
    warnings[#warnings + 1] = ('%s returned a whole-file string rewrite; it claims bytes 1..%d and will conflict with every other plugin on this file')
      :format(owner, n)
    return hunks, warnings
  end

  if type(result) ~= 'table' then
    warnings[#warnings + 1] = ('%s returned a %s from OnSetText; expected nil, string or diff table'):format(owner, type(result))
    return hunks, warnings
  end

  local numeric_count = 0
  for k in pairs(result) do
    if type(k) == 'number' then
      if k % 1 ~= 0 or k < 1 or k > #result then
        return {}, {owner .. ' returned a non-dense or malformed diff array; dropped'}
      end
      numeric_count = numeric_count + 1
    end
  end
  if numeric_count ~= #result then return {}, {owner .. ' returned a non-dense diff array; dropped'} end

  for i, h in ipairs(result) do
    if type(h) ~= 'table' or type(h.start) ~= 'number'
      or type(h.finish) ~= 'number' or type(h.text) ~= 'string'
      or h.start % 1 ~= 0 or h.finish % 1 ~= 0 then
      warnings[#warnings + 1] = ('%s hunk #%d is malformed (need numeric start/finish and string text); dropped'):format(owner, i)
    elseif h.start < 1 or h.start > n + 1 or h.finish < h.start - 1 or h.finish > n then
      warnings[#warnings + 1] = ('%s hunk #%d has out-of-range span [%d,%d] for a %d-byte file; dropped')
        :format(owner, i, h.start, h.finish, n)
    elseif h.start == 1 and h.finish == n and h.text == text then
      -- An identity whole-file replacement. hydronium-luax used to emit one of
      -- these for a JSX-free `.luax` file. It changes nothing yet claims every
      -- byte, so it silently starves every other plugin. Dropping it is a
      -- defence-in-depth mitigation; the real fix belongs in the emitting
      -- plugin, and has been applied upstream in hydronium-luax.
      warnings[#warnings + 1] = ('%s emitted a no-op whole-file replacement; dropped (it would have starved every other plugin)'):format(owner)
    else
      hunks[#hunks + 1] = { start = h.start, finish = h.finish, text = h.text }
    end
  end

  return hunks, warnings
end

--------------------------------------------------------------------------
-- resolve
--------------------------------------------------------------------------

--- Do two spans intersect? Insertions have zero width and are handled
--- separately, so this is only ever asked about replacements.
local function overlaps(a_start, a_finish, b_start, b_finish)
  return a_start <= b_finish and b_start <= a_finish
end

--- Drop hunks that cannot coexist, preferring lower `priority` numbers.
---
--- Two rules, both derived from `cur` monotonicity in `mergeDiff`:
---
---   * two REPLACEMENTS whose spans intersect cannot both apply — the second
---     one's `start` is inside the first's consumed range, so `cur` would move
---     backward;
---   * an INSERTION at `p` strictly inside a surviving replacement `[s,f]`
---     (that is, `s < p <= f`) has the same problem: the replacement runs
---     first (lower start), leaving `cur = f + 1 > p`.
---
--- An insertion at `p == s` is fine — coalescing puts it ahead of the
--- replacement — and one at `p == f + 1` is simply the next position.
---
---@param hunks table   each with .start .finish .text .owner .priority .seq
---@return table kept
---@return table dropped
function M.resolve(hunks)
  local ordered = {}
  for i, h in ipairs(hunks) do ordered[i] = h end
  -- Resolve in plugin-priority order so the highest-priority plugin always
  -- keeps its hunk, regardless of where in the file it happens to sit.
  table.sort(ordered, function(a, b)
    if a.priority ~= b.priority then return a.priority < b.priority end
    return a.seq < b.seq
  end)

  local kept, dropped = {}, {}
  local claimed = {}

  -- Pass 1: replacements against each other.
  for _, h in ipairs(ordered) do
    if not M.is_insertion(h) then
      local clash
      for _, c in ipairs(claimed) do
        if overlaps(h.start, h.finish, c.start, c.finish) then clash = c break end
      end
      if clash then
        h.conflict_with = clash
        h.conflict_kind = 'overlapping-replacement'
        dropped[#dropped + 1] = h
      else
        claimed[#claimed + 1] = h
        kept[#kept + 1] = h
      end
    end
  end

  -- Pass 2: insertions against the replacements that survived.
  for _, h in ipairs(ordered) do
    if M.is_insertion(h) then
      local clash
      for _, c in ipairs(claimed) do
        if c.start < h.start and h.start <= c.finish then clash = c break end
      end
      if clash then
        h.conflict_with = clash
        h.conflict_kind = 'insertion-inside-replacement'
        dropped[#dropped + 1] = h
      else
        kept[#kept + 1] = h
      end
    end
  end

  return kept, dropped
end

--------------------------------------------------------------------------
-- coalesce
--------------------------------------------------------------------------

--- Fuse hunks sharing a `start` into a single hunk, so the returned list has
--- strictly increasing, non-overlapping, distinct-`start` spans.
---
--- After `resolve` a group at offset `p` holds any number of insertions and at
--- most one replacement (two replacements at the same start always intersect).
--- Insertion text is emitted first — "insert before byte p" precedes "replace
--- byte p" — then the replacement's text. The group's `finish` is the
--- replacement's `finish`, or `p - 1` when the group is insertions only.
---
---@param kept table
---@return table diffs   plain {start,finish,text} hunks, ascending
function M.coalesce(kept)
  local ordered = {}
  for i, h in ipairs(kept) do ordered[i] = h end
  table.sort(ordered, function(a, b)
    if a.start ~= b.start then return a.start < b.start end
    local ai, bi = M.is_insertion(a), M.is_insertion(b)
    if ai ~= bi then return ai end            -- insertions before the replacement
    if a.priority ~= b.priority then return a.priority < b.priority end
    return a.seq < b.seq
  end)

  local diffs = {}
  local cur
  for _, h in ipairs(ordered) do
    if cur and cur.start == h.start then
      cur.text = cur.text .. h.text
      if h.finish > cur.finish then cur.finish = h.finish end
    else
      cur = { start = h.start, finish = h.finish, text = h.text }
      diffs[#diffs + 1] = cur
    end
  end
  return diffs
end

--------------------------------------------------------------------------
-- merge
--------------------------------------------------------------------------

--- Merge every child's contribution into one canonical diff list.
---
---@param contributions table  array of { name = string, result = any }, in
---                            priority order (index 1 = highest priority)
---@param text string          the ORIGINAL document text
---@return table? diffs        nil when nothing changes, else a diff array
---@return table report        { warnings = string[], dropped = table[] }
function M.merge(contributions, text)
  local report = { warnings = {}, dropped = {} }
  local hunks = {}
  local seq = 0

  for priority, c in ipairs(contributions) do
    local list, warns = M.normalise(c.result, text, c.name)
    for _, w in ipairs(warns) do report.warnings[#report.warnings + 1] = w end
    for _, h in ipairs(list) do
      seq = seq + 1
      h.owner, h.priority, h.seq = c.name, priority, seq
      hunks[#hunks + 1] = h
    end
  end

  if #hunks == 0 then
    return nil, report
  end

  local kept, dropped = M.resolve(hunks)
  report.dropped = dropped

  for _, h in ipairs(dropped) do
    local c = h.conflict_with
    local cowner = c and c.owner or '?'
    local cstart, cfinish = c and c.start or -1, c and c.finish or -1
    if h.conflict_kind == 'insertion-inside-replacement' then
      -- Priority is irrelevant here: an insertion cannot survive inside a range
      -- another plugin replaces wholesale, no matter who ranks higher. Say so,
      -- rather than implying the loser was merely outranked.
      report.warnings[#report.warnings + 1] = (
        'conflict: dropped %s insertion at byte %d — it falls inside the range [%d,%d] that %s replaces wholesale, ' ..
        'so it cannot be applied at all. %s will contribute nothing to this file.'
      ):format(h.owner, h.start, cstart, cfinish, cowner, h.owner)
    else
      report.warnings[#report.warnings + 1] = (
        'conflict: dropped %s hunk [%d,%d] because it overlaps %s hunk [%d,%d], which is configured at a higher priority'
      ):format(h.owner, h.start, h.finish, cowner, cstart, cfinish)
    end
  end

  if #kept == 0 then
    return nil, report
  end

  return M.coalesce(kept), report
end

--- Reference implementation of LuaLS's `string-merger.mergeDiff`, for tests.
--- Kept byte-identical in behaviour to `script/string-merger.lua:51-76` so a
--- test can assert what LuaLS would actually produce, including the
--- `cur`-moves-backward duplication bug.
---@param text string
---@param diffs table
---@return string
function M.apply(text, diffs)
  local info = {}
  for i, d in ipairs(diffs) do
    info[i] = { start = d.start, finish = d.finish, text = d.text }
  end
  table.sort(info, function(a, b) return a.start < b.start end)
  local cur, buf = 1, {}
  for _, d in ipairs(info) do
    buf[#buf + 1] = text:sub(cur, d.start - 1)
    buf[#buf + 1] = d.text
    cur = d.finish + 1
  end
  buf[#buf + 1] = text:sub(cur)
  return table.concat(buf)
end

return M
