// Copyright 2026 International Digital Economy Academy
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
/// The weight class of a token. Weights encode semantic importance for the
/// alignment scorer: identifiers and literals carry full signal, punctuation
/// less, comment content little, and comment boilerplate / whitespace none to
/// almost none.
pub(all) enum TokKind {
  Word // identifiers, keywords, numbers
  Str // string / char / bytes / regex literals (one token each)
  Punct // operators, brackets, separators
  Comment // content tokens inside a comment (tokenized, never opaque)
  Filler // comment boilerplate: `//` markers and comment whitespace
  Space // inter-token whitespace (reconstructed from lexer position gaps)
} derive(Eq)

///|
/// One diffable token: its weight class and its exact source text.
/// Concatenating the `text` of `tokenize_line`'s result reproduces the line.
pub struct Tok {
  kind : TokKind
  text : String
}

///|
pub fn Tok::kind(self : Tok) -> TokKind {
  self.kind
}

///|
pub fn Tok::text(self : Tok) -> String {
  self.text
}

///|
/// The alignment weight of a token class (integer; all scoring is integer so
/// results are bit-identical on every backend).
pub fn weight(k : TokKind) -> Int {
  match k {
    Word | Str => 20
    Punct => 6
    Comment => 2
    Space => 1
    Filler => 0
  }
}

///|
/// Tokenize the inside of a comment: words keep a little weight so similar
/// comments pair (and identical comments win ties), while the `//` markers
/// and comment spacing are weightless `Filler` — shared boilerplate must not
/// make unrelated comments look similar.
fn push_comment_tokens(toks : Array[Tok], body : String) -> Unit {
  let mut rest = body.view()
  while rest is [_, ..] {
    rest = lexscan rest with longest {
      (re"^//+" as t, after=next) => {
        toks.push({ kind: Filler, text: t.to_owned() })
        next
      }
      (re"^[ \t]+" as t, after=next) => {
        toks.push({ kind: Filler, text: t.to_owned() })
        next
      }
      (re"^[A-Za-z0-9_]+" as t, after=next) => {
        toks.push({ kind: Comment, text: t.to_owned() })
        next
      }
      (re"^." as t, after=next) => {
        toks.push({ kind: Comment, text: t.to_string() })
        next
      }
      _ => abort("unreachable")
    }
  }
}

///|
fn classify(tok : @tokens.Token, text : String) -> TokKind {
  match tok {
    CHAR(_)
    | BYTE(_)
    | BYTES(_)
    | STRING(_)
    | MULTILINE_STRING(_)
    | MULTILINE_INTERP(_)
    | INTERP(_)
    | REGEX_LITERAL(_)
    | REGEX_INTERP(_) => Str
    _ =>
      match text {
        [c, ..] if (c >= 'a' && c <= 'z') ||
          (c >= 'A' && c <= 'Z') ||
          c == '_' ||
          (c >= '0' && c <= '9') => Word
        _ => Punct
      }
  }
}

///|
/// Tokenize one line of MoonBit source with the real MoonBit lexer
/// (`moonbitlang/lexer`), mapping language tokens to weight classes:
///
/// - identifiers / keywords / numbers -> `Word`
/// - string, char, bytes and regex literals -> `Str` (one token each)
/// - operators and separators -> `Punct`
/// - comments -> content-tokenized `Comment` words + weightless `Filler`
/// - gaps between token spans (whitespace the lexer skipped) -> `Space`,
///   reconstructed from positions so concatenation reproduces the line
///
/// Lexical errors are ignored (diffs are routinely taken of incomplete
/// code); the lexer's best-effort token stream is used as is.
pub fn tokenize_line(line : String) -> Array[Tok] {
  let toks : Array[Tok] = []
  let r = @lexer.tokens_from_string_with_utf16_location(comment=true, line)
  let mut prev_end = 0
  for triple in r.tokens {
    let (tok, sp, ep) = triple
    if tok is (NEWLINE | EOF) {
      continue
    }
    if sp.cnum > prev_end {
      toks.push({
        kind: Space,
        text: line.view(start_offset=prev_end, end_offset=sp.cnum).to_owned(),
      })
    }
    let text = line.view(start_offset=sp.cnum, end_offset=ep.cnum).to_owned()
    match tok {
      COMMENT(_) => push_comment_tokens(toks, text)
      _ => toks.push({ kind: classify(tok, text), text })
    }
    prev_end = ep.cnum
  }
  if prev_end < line.length() {
    toks.push({ kind: Space, text: line.view(start_offset=prev_end).to_owned() })
  }
  toks
}
