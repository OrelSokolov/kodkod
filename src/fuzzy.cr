# Fuzzy matching with optimal subsequence scoring (same semantics as
# the hcode finder — tuned like fzf / VS Code fuzzy matching).
#
# All query characters must appear in order within the text (subsequence
# match). Among the many ways to align the query to the text, the DP
# picks the alignment that maximizes a quality score so the best matches
# surface first. Scoring signals:
#
#   * boundary bonus  — match right after a separator (`-`, `_`, ` `, `.`,
#     `/`, digits, or at the start of the text)
#   * camelCase bonus — match an uppercase letter that follows a lowercase one
#   * consecutive bonus — match adjacent to the previous matched character
#   * gap penalty    — per skipped character between two matches
#
# `Fuzzy.match` returns the score plus the exact matched positions (for
# highlighting); `Fuzzy.filter` keeps only matching items and ranks them
# by score, breaking ties by original order.
#
# The DP is O(m·n) (fzf-style): S[j][i] is the best alignment ending
# with query[j] on text[i]; a rolling P row carries "best prefix
# alignment ending at or before i", charging the gap penalty per skipped
# character — that replaces the O(n) max-scan over previous matches the
# naive formulation needs per cell. Positions are reconstructed by
# re-walking the stored S rows.

module Kodkod
  module Fuzzy
    # Base score awarded for every matched character.
    MATCH_SCORE = 16
    # Bonus for matching at a word boundary (after a separator or at index 0).
    BONUS_BOUNDARY = 10
    # Bonus for matching the uppercase letter in a camelCase boundary.
    BONUS_CAMEL = 8
    # Bonus when the current match is adjacent to the previous one.
    BONUS_CONSECUTIVE = 18
    # Penalty applied for each character skipped between two matched chars.
    GAP_PENALTY = 2

    # Sentinel meaning "no valid alignment reaches this cell".
    NEG_INF = Int32::MIN // 2

    struct Result
      getter score : Int32
      # Indices into the original text that matched the query, ascending.
      getter positions : Array(Int32)

      def initialize(@score : Int32, @positions : Array(Int32))
      end
    end

    # Returns a `Result` (score + matched positions) when *query* is a
    # subsequence of *text* (case-insensitive), otherwise `nil`.
    # *down_query* / *down_text* let a caller that pre-lowercased both
    # strings (a file list re-filtered per keystroke) skip the work.
    def self.match(query : String, text : String,
                   down_query : String? = nil,
                   down_text : String? = nil) : Result?
      return nil if query.empty?
      return nil if query.size > text.size

      m = query.size
      n = text.size
      dq = down_query || query.downcase
      dt = down_text || text.downcase
      bonus = compute_bonus(text)

      # One query character: no alignment choices — take the best spot.
      if m == 1
        q0 = dq.char_at(0)
        best_i = -1
        best = NEG_INF
        n.times do |i|
          next unless dt.char_at(i) == q0
          s = MATCH_SCORE + bonus[i] - GAP_PENALTY * i
          if s > best
            best = s
            best_i = i
          end
        end
        return nil if best_i < 0
        return Result.new(best, [best_i])
      end

      # S[j*n + i] = best score aligning query[0..j] so that text[i]
      # matches query[j]; NEG_INF when text[i] cannot be the j-th match.
      s = Array.new(m * n, NEG_INF)
      # P rows roll: p_prev[i] = best score with query[j-1] matched at
      # some k <= i, gap penalty charged per skipped position.
      p_prev = Array.new(n, NEG_INF)
      p_cur = Array.new(n, NEG_INF)

      q0 = dq.char_at(0)
      n.times do |i|
        s[i] = MATCH_SCORE + bonus[i] - GAP_PENALTY * i if dt.char_at(i) == q0
        p_prev[i] = i == 0 ? s[0] : {s[i], p_prev[i - 1] - GAP_PENALTY}.max
      end

      (1...m).each do |j|
        qj = dq.char_at(j)
        # i must leave room for the remaining (m-1-j) query chars after
        # it, so the valid range is [j, n-m+j].
        (j..(n - m + j)).each do |i|
          next unless dt.char_at(i) == qj
          # The consecutive path is only real when the DIAGONAL
          # predecessor is a live cell — adding BONUS_CONSECUTIVE to
          # NEG_INF would "pass" the > NEG_INF guard and poison the
          # row (score arithmetic on the sentinel).
          prev_s = s[(j - 1) * n + (i - 1)]
          consec = prev_s > NEG_INF ? prev_s + BONUS_CONSECUTIVE : NEG_INF
          skipped = p_prev[i - 1]
          best_prev = {consec, skipped}.max
          next unless best_prev > NEG_INF
          s[j * n + i] = best_prev + MATCH_SCORE + bonus[i]
        end
        (j...n).each do |i|
          p_cur[i] = {s[j * n + i],
                      p_cur[i - 1] - GAP_PENALTY}.max
        end
        p_prev, p_cur = p_cur, p_prev
        p_cur.fill(NEG_INF)
      end

      # Pick the best endpoint in the last row.
      best_end = -1
      best_total = NEG_INF
      ((m - 1)...n).each do |i|
        if s[(m - 1) * n + i] > best_total
          best_total = s[(m - 1) * n + i]
          best_end = i
        end
      end
      return nil if best_end < 0 || best_total <= NEG_INF

      # Reconstruct matched positions by walking the rows backwards:
      # an adjacent predecessor (the consecutive path) is detectable
      # from S alone; otherwise find the k <= i-1 whose prefix value
      # (score minus the gap penalty for the skip) carries the cell.
      positions = Array.new(m, 0)
      positions[m - 1] = best_end
      i = best_end
      (m - 1).downto(1) do |j|
        adj = s[(j - 1) * n + (i - 1)]
        if adj > NEG_INF &&
           s[j * n + i] == adj + MATCH_SCORE + bonus[i] + BONUS_CONSECUTIVE
          i = i - 1
        else
          # P[j-1][i-1] = max over k of S[j-1][k] - GAP*(i-1-k); the k
          # achieving it is the predecessor. Scan ascending like the
          # naive DP did, so tie-breaking picks the same alignment.
          best_k = -1
          best_p = NEG_INF
          ((j - 1)..(i - 1)).each do |k|
            prev = s[(j - 1) * n + k]
            next unless prev > NEG_INF
            cand = prev - GAP_PENALTY * (i - 1 - k)
            if cand > best_p
              best_p = cand
              best_k = k
            end
          end
          return nil if best_k < 0 # corrupted state — must not happen
          i = best_k
        end
        positions[j - 1] = i
      end

      Result.new(best_total, positions)
    end

    # True when *query* is a case-insensitive subsequence of *text*.
    def self.matches?(query : String, text : String) : Bool
      return false if query.empty?
      return false if query.size > text.size
      subsequence?(query.downcase, text.downcase)
    end

    # Filters *items* keeping only those matching *query*, returning their
    # original indices sorted by descending fuzzy score (stable on ties so
    # equal-scoring items keep their input order).
    #
    # The cheap subsequence gate runs FIRST — the scoring DP is slower
    # and must only see real candidates (a keystroke over thousands of
    # paths stays interactive).
    def self.filter(items : Array(String), query : String) : Array({Int32, Result})
      return [] of {Int32, Result} if query.empty?
      dq = query.downcase
      results = [] of {Int32, Result}
      items.each_with_index do |item, idx|
        next unless subsequence?(dq, item.downcase)
        if res = match(query, item, down_query: dq)
          results << {idx, res}
        end
      end
      # Sort by score desc, then original index asc for stability.
      results.sort_by! { |idx, res| {-res.score, idx} }
      results
    end

    # True when the already-lowercased *dq* is a subsequence of the
    # already-lowercased *dt* — allocation-free fast path.
    private def self.subsequence?(dq : String, dt : String) : Bool
      size = dq.size
      qi = 0
      dt.each_char do |c|
        qi += 1 if c == dq.char_at(qi)
        return true if qi >= size
      end
      qi >= size
    end

    # Bonus weight for matching the character at index *i* of *text*.
    private def self.compute_bonus(text : String) : Array(Int32)
      n = text.size
      arr = Array.new(n, 0)
      n.times do |i|
        if i == 0
          arr[0] = BONUS_BOUNDARY
        else
          prev = text.char_at(i - 1)
          cur = text.char_at(i)
          arr[i] = if separator?(prev)
                     BONUS_BOUNDARY
                   elsif prev.lowercase? && cur.uppercase?
                     BONUS_CAMEL
                   elsif prev.ascii_number? && cur.ascii_letter?
                     BONUS_BOUNDARY
                   else
                     0
                   end
        end
      end
      arr
    end

    private def self.separator?(c : Char) : Bool
      !c.ascii_alphanumeric?
    end
  end
end
