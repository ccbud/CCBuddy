//! Markdown-safe Responses citation rendering ported from cc-switch.

use serde_json::Value;
use std::collections::HashSet;

fn has_http_url_scheme(value: &str) -> bool {
    value
        .get(.."http://".len())
        .is_some_and(|scheme| scheme.eq_ignore_ascii_case("http://"))
        || value
            .get(.."https://".len())
            .is_some_and(|scheme| scheme.eq_ignore_ascii_case("https://"))
}

fn markdown_link_label(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        if character.is_whitespace() {
            escaped.push(' ');
        } else if character.is_control() {
            escaped.push('\u{fffd}');
        } else {
            match character {
                '&' => escaped.push_str("&amp;"),
                '<' => escaped.push_str("&lt;"),
                '>' => escaped.push_str("&gt;"),
                character if character.is_ascii_punctuation() => {
                    escaped.push('\\');
                    escaped.push(character);
                }
                character => escaped.push(character),
            }
        }
    }
    escaped
}

fn markdown_link_destination(value: &str) -> Option<String> {
    let value = value.trim();
    if !has_http_url_scheme(value) || value.chars().any(char::is_control) {
        return None;
    }
    Some(
        value
            .replace('\\', "%5C")
            .replace(' ', "%20")
            .replace('(', "%28")
            .replace(')', "%29")
            .replace('<', "%3C")
            .replace('>', "%3E"),
    )
}

fn char_index_to_byte_offset(text: &str, index: usize) -> Option<usize> {
    if index == text.chars().count() {
        Some(text.len())
    } else {
        text.char_indices()
            .nth(index)
            .map(|(byte_offset, _)| byte_offset)
    }
}

fn is_markdown_escaped(text: &str, byte_offset: usize) -> bool {
    text.as_bytes()[..byte_offset]
        .iter()
        .rev()
        .take_while(|byte| **byte == b'\\')
        .count()
        % 2
        == 1
}

struct MarkdownBracketPairs {
    opening_to_closing: Vec<Option<usize>>,
    closing_to_opening: Vec<Option<(usize, bool)>>,
}

fn markdown_bracket_pairs(text: &str, code_mask: &[bool]) -> MarkdownBracketPairs {
    let bytes = text.as_bytes();
    let mut opening_to_closing = vec![None; bytes.len()];
    let mut closing_to_opening = vec![None; bytes.len()];
    let mut openings = Vec::new();
    let mut preceding_backslashes = 0_usize;
    for (offset, byte) in bytes.iter().copied().enumerate() {
        if code_mask.get(offset).copied().unwrap_or_default() {
            preceding_backslashes = 0;
            continue;
        }
        if byte == b'\\' {
            preceding_backslashes += 1;
            continue;
        }
        let escaped = preceding_backslashes % 2 == 1;
        preceding_backslashes = 0;
        if escaped {
            continue;
        }
        match byte {
            b'[' => openings.push(offset),
            b']' => {
                let Some(opening) = openings.pop() else {
                    continue;
                };
                let is_image = opening > 0
                    && bytes[opening - 1] == b'!'
                    && !is_markdown_escaped(text, opening - 1);
                opening_to_closing[opening] = Some(offset);
                closing_to_opening[offset] = Some((opening, is_image));
            }
            _ => {}
        }
    }
    MarkdownBracketPairs {
        opening_to_closing,
        closing_to_opening,
    }
}

fn markdown_list_marker_end(line: &[u8], start: usize) -> Option<usize> {
    let marker_end = match *line.get(start)? {
        b'-' | b'+' | b'*' => start + 1,
        byte if byte.is_ascii_digit() => {
            let digit_count = line[start..]
                .iter()
                .take(9)
                .take_while(|byte| byte.is_ascii_digit())
                .count();
            let delimiter = start + digit_count;
            if digit_count == 0 || !matches!(line.get(delimiter), Some(b'.' | b')')) {
                return None;
            }
            delimiter + 1
        }
        _ => return None,
    };
    if !line
        .get(marker_end)
        .is_some_and(|byte| matches!(byte, b' ' | b'\t'))
    {
        return None;
    }

    // CommonMark list padding is one to four spaces. Five or more spaces use
    // one column of list padding and leave an indented-code prefix behind.
    if line[marker_end] == b'\t' {
        return Some(marker_end + 1);
    }
    let spaces = line[marker_end..]
        .iter()
        .take_while(|byte| **byte == b' ')
        .count();
    Some(marker_end + if spaces <= 4 { spaces } else { 1 })
}

#[derive(Clone)]
enum MarkdownContainerToken {
    BlockQuote,
    List { continuation_indent: usize },
}

#[derive(Default)]
struct MarkdownContainerPrefix {
    content_start: usize,
    tokens: Vec<MarkdownContainerToken>,
}

fn markdown_container_prefix(line: &[u8]) -> MarkdownContainerPrefix {
    let mut offset = 0;
    let mut tokens = Vec::new();
    loop {
        let indentation = line[offset..]
            .iter()
            .take_while(|byte| **byte == b' ')
            .count();
        if indentation > 3 {
            break;
        }
        let marker_start = offset + indentation;
        if line.get(marker_start) == Some(&b'>') {
            offset = marker_start + 1;
            if line
                .get(offset)
                .is_some_and(|byte| matches!(byte, b' ' | b'\t'))
            {
                offset += 1;
            }
            tokens.push(MarkdownContainerToken::BlockQuote);
            continue;
        }
        if let Some(end) = markdown_list_marker_end(line, marker_start) {
            tokens.push(MarkdownContainerToken::List {
                continuation_indent: end - offset,
            });
            offset = end;
            continue;
        }
        break;
    }
    MarkdownContainerPrefix {
        content_start: if tokens.is_empty() { 0 } else { offset },
        tokens,
    }
}

fn markdown_container_continuation_start(
    line: &[u8],
    tokens: &[MarkdownContainerToken],
) -> Option<usize> {
    let mut offset = 0;
    for token in tokens {
        match token {
            MarkdownContainerToken::BlockQuote => {
                let indentation = line[offset..]
                    .iter()
                    .take_while(|byte| **byte == b' ')
                    .count();
                if indentation > 3 {
                    return None;
                }
                let marker_start = offset + indentation;
                if line.get(marker_start) != Some(&b'>') {
                    return None;
                }
                offset = marker_start + 1;
                if line
                    .get(offset)
                    .is_some_and(|byte| matches!(byte, b' ' | b'\t'))
                {
                    offset += 1;
                }
            }
            MarkdownContainerToken::List {
                continuation_indent,
            } => {
                let mut columns = 0;
                let mut consumed = 0;
                for byte in &line[offset..] {
                    match *byte {
                        b' ' => columns += 1,
                        b'\t' => columns += 4 - (columns % 4),
                        _ => break,
                    }
                    consumed += 1;
                    if columns >= *continuation_indent {
                        break;
                    }
                }
                if columns < *continuation_indent {
                    return None;
                }
                offset += consumed;
            }
        }
    }
    Some(offset)
}

fn markdown_fence_at(line: &[u8], content_start: usize) -> Option<(u8, usize, usize)> {
    let indentation = line[content_start..]
        .iter()
        .take_while(|byte| **byte == b' ')
        .count();
    if indentation > 3 {
        return None;
    }
    let marker_start = content_start + indentation;
    let marker = *line.get(marker_start)?;
    if !matches!(marker, b'`' | b'~') {
        return None;
    }
    let length = line[marker_start..]
        .iter()
        .take_while(|byte| **byte == marker)
        .count();
    (length >= 3).then_some((marker, length, marker_start + length))
}

#[derive(Clone)]
struct MarkdownFence {
    marker: u8,
    minimum_length: usize,
    containers: Vec<MarkdownContainerToken>,
}

fn markdown_fence(line: &[u8]) -> Option<(MarkdownFence, usize)> {
    let container = markdown_container_prefix(line);
    let (marker, minimum_length, suffix_start) = markdown_fence_at(line, container.content_start)?;
    Some((
        MarkdownFence {
            marker,
            minimum_length,
            containers: container.tokens,
        },
        suffix_start,
    ))
}

fn markdown_indentation_columns(line: &[u8]) -> usize {
    let mut columns = 0;
    for byte in line {
        match *byte {
            b' ' => columns += 1,
            b'\t' => columns += 4 - (columns % 4),
            _ => break,
        }
    }
    columns
}

struct MarkdownCodeScan {
    mask: Vec<bool>,
    unterminated_fence: Option<(u8, usize)>,
}

fn markdown_code_scan(text: &str) -> MarkdownCodeScan {
    let bytes = text.as_bytes();
    let mut mask = vec![false; bytes.len()];
    let mut fence: Option<MarkdownFence> = None;
    let mut in_indented_code = false;
    let mut previous_line_blank = true;
    let mut line_start = 0;
    while line_start < bytes.len() {
        let line_end = bytes[line_start..]
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(bytes.len(), |offset| line_start + offset + 1);
        let line = &bytes[line_start..line_end];
        let line_blank = line.iter().all(|byte| byte.is_ascii_whitespace());
        let indentation = markdown_indentation_columns(line);
        let mut handled_by_fence = false;
        if let Some(open_fence) = fence.clone() {
            let content_start = if open_fence.containers.is_empty() {
                Some(0)
            } else {
                markdown_container_continuation_start(line, &open_fence.containers)
            };
            if let Some(content_start) = content_start {
                handled_by_fence = true;
                mask[line_start..line_end].fill(true);
                if let Some((candidate, length, suffix_start)) =
                    markdown_fence_at(line, content_start)
                {
                    if candidate == open_fence.marker
                        && length >= open_fence.minimum_length
                        && line[suffix_start..]
                            .iter()
                            .all(|byte| byte.is_ascii_whitespace())
                    {
                        fence = None;
                    }
                }
            } else {
                // A fenced block cannot outlive its blockquote/list container.
                // Re-process this line as top-level Markdown.
                fence = None;
            }
        }
        if !handled_by_fence {
            let mut handled_as_indented = false;
            if in_indented_code {
                if line_blank || indentation >= 4 {
                    mask[line_start..line_end].fill(true);
                    handled_as_indented = true;
                } else {
                    in_indented_code = false;
                }
            }
            if !handled_as_indented && indentation >= 4 && previous_line_blank {
                mask[line_start..line_end].fill(true);
                in_indented_code = true;
                handled_as_indented = true;
            }
            if !handled_as_indented {
                if let Some((new_fence, suffix_start)) = markdown_fence(line) {
                    // A backtick fence's info string cannot itself contain a backtick.
                    // Treat such a line as ordinary text instead of masking the rest
                    // of the response as an unterminated code block.
                    if new_fence.marker != b'`' || !line[suffix_start..].contains(&b'`') {
                        mask[line_start..line_end].fill(true);
                        fence = Some(new_fence);
                    }
                }
            }
        }
        previous_line_blank = line_blank;
        line_start = line_end;
    }

    let mut offset = 0;
    while offset < bytes.len() {
        if mask[offset] || bytes[offset] != b'`' || is_markdown_escaped(text, offset) {
            offset += 1;
            continue;
        }
        let delimiter_length = bytes[offset..]
            .iter()
            .take_while(|byte| **byte == b'`')
            .count();
        let mut candidate = offset + delimiter_length;
        let mut closing = None;
        while candidate < bytes.len() {
            if mask[candidate] {
                candidate += 1;
                continue;
            }
            // Backslashes have no escaping semantics inside a code span.
            if bytes[candidate] != b'`' {
                candidate += 1;
                continue;
            }
            let candidate_length = bytes[candidate..]
                .iter()
                .take_while(|byte| **byte == b'`')
                .count();
            if candidate_length == delimiter_length {
                closing = Some(candidate + candidate_length);
                break;
            }
            candidate += candidate_length;
        }
        if let Some(closing) = closing {
            mask[offset..closing].fill(true);
            offset = closing;
        } else {
            offset += delimiter_length;
        }
    }
    MarkdownCodeScan {
        mask,
        unterminated_fence: fence
            .filter(|fence| fence.containers.is_empty())
            .map(|fence| (fence.marker, fence.minimum_length)),
    }
}

fn markdown_link_suffix_end(rest: &str) -> Option<usize> {
    if rest.starts_with(')') {
        return Some(1);
    }
    if !rest.chars().next().is_some_and(char::is_whitespace) {
        return None;
    }

    let trimmed = rest.trim_start_matches(char::is_whitespace);
    let leading_whitespace = rest.len() - trimmed.len();
    let rest = trimmed;
    if rest.starts_with(')') {
        return Some(leading_whitespace + 1);
    }
    let delimiter = rest
        .chars()
        .next()
        .filter(|ch| matches!(ch, '"' | '\'' | '('))?;
    let closing_delimiter = if delimiter == '(' { ')' } else { delimiter };
    let title = &rest[delimiter.len_utf8()..];
    let closing_offset = title
        .char_indices()
        .find(|(offset, ch)| *ch == closing_delimiter && !is_markdown_escaped(title, *offset))
        .map(|(offset, _)| offset)?;
    let after_title = &title[closing_offset + closing_delimiter.len_utf8()..];
    let trimmed_after_title = after_title.trim_start_matches(char::is_whitespace);
    trimmed_after_title.starts_with(')').then_some(
        leading_whitespace
            + delimiter.len_utf8()
            + closing_offset
            + closing_delimiter.len_utf8()
            + (after_title.len() - trimmed_after_title.len())
            + 1,
    )
}

fn markdown_link_suffix_is_closed(rest: &str) -> bool {
    markdown_link_suffix_end(rest).is_some()
}

fn markdown_inline_destination_end(destination: &str) -> Option<usize> {
    if let Some(angle_destination) = destination.strip_prefix('<') {
        let closing = angle_destination
            .char_indices()
            .find(|(offset, character)| {
                *character == '>' && !is_markdown_escaped(angle_destination, *offset)
            })
            .map(|(offset, _)| offset)?;
        let suffix_start = 1 + closing + 1;
        return markdown_link_suffix_end(&destination[suffix_start..])
            .map(|suffix_length| suffix_start + suffix_length);
    }

    let mut parentheses = 0_u32;
    let mut escaped = false;
    for (offset, character) in destination.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if character == '\\' {
            escaped = true;
            continue;
        }
        match character {
            '<' | '>' if parentheses == 0 => return None,
            '(' => parentheses += 1,
            ')' if parentheses == 0 => return Some(offset + 1),
            ')' => parentheses -= 1,
            character if character.is_whitespace() && parentheses == 0 => {
                return markdown_link_suffix_end(&destination[offset..])
                    .map(|suffix_length| offset + suffix_length);
            }
            _ => {}
        }
    }
    None
}

fn is_valid_bare_markdown_destination(value: &str) -> bool {
    if value.is_empty()
        || value
            .chars()
            .any(|character| character.is_whitespace() || character.is_control())
        || value.contains(['<', '>', '\\'])
    {
        return false;
    }

    let mut parentheses = 0_u32;
    for character in value.chars() {
        match character {
            '(' => parentheses += 1,
            ')' if parentheses == 0 => return false,
            ')' => parentheses -= 1,
            _ => {}
        }
    }
    parentheses == 0
}

fn is_valid_markdown_autolink_destination(value: &str) -> bool {
    !value.is_empty()
        && !value.chars().any(|character| {
            character.is_whitespace()
                || character.is_control()
                || matches!(character, '<' | '>' | '\\')
        })
}

fn markdown_closing_bracket(text: &str, opening_bracket: usize) -> Option<usize> {
    let bytes = text.as_bytes();
    let mut nested = 0_u32;
    for (offset, byte) in bytes.iter().enumerate().skip(opening_bracket + 1) {
        if is_markdown_escaped(text, offset) {
            continue;
        }
        match byte {
            b'[' => nested += 1,
            b']' if nested == 0 => return Some(offset),
            b']' => nested -= 1,
            _ => {}
        }
    }
    None
}

fn normalize_markdown_reference_label(label: &str) -> String {
    label
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

#[derive(Clone)]
struct MarkdownReferenceDefinition {
    label: String,
    destination: String,
    line_start: usize,
    line_end: usize,
}

fn markdown_reference_destination(value: &str) -> Option<&str> {
    let value = value.trim_start_matches(char::is_whitespace);
    if let Some(angle_destination) = value.strip_prefix('<') {
        let closing = angle_destination
            .char_indices()
            .find(|(offset, character)| {
                *character == '>' && !is_markdown_escaped(angle_destination, *offset)
            })
            .map(|(offset, _)| offset)?;
        return Some(&angle_destination[..closing]);
    }

    let mut parentheses = 0_u32;
    let mut escaped = false;
    for (offset, character) in value.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if character == '\\' {
            escaped = true;
            continue;
        }
        match character {
            '(' => parentheses += 1,
            ')' if parentheses == 0 => return None,
            ')' => parentheses -= 1,
            character if character.is_whitespace() && parentheses == 0 => {
                return (offset > 0).then_some(&value[..offset]);
            }
            _ => {}
        }
    }
    (!value.is_empty() && parentheses == 0).then_some(value)
}

fn markdown_reference_definitions(
    text: &str,
    code_mask: &[bool],
) -> Vec<MarkdownReferenceDefinition> {
    let bytes = text.as_bytes();
    let mut definitions = Vec::new();
    let mut line_start = 0;
    while line_start < bytes.len() {
        let line_end = bytes[line_start..]
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(bytes.len(), |offset| line_start + offset + 1);
        let line = &text[line_start..line_end];
        if code_mask.get(line_start).copied().unwrap_or_default() {
            line_start = line_end;
            continue;
        }
        let indentation = line
            .as_bytes()
            .iter()
            .take_while(|byte| **byte == b' ')
            .count();
        if indentation <= 3 && line.as_bytes().get(indentation) == Some(&b'[') {
            if let Some(closing) = markdown_closing_bracket(line, indentation) {
                if line.as_bytes().get(closing + 1) == Some(&b':') {
                    let label = normalize_markdown_reference_label(&line[indentation + 1..closing]);
                    if !label.is_empty() {
                        if let Some(destination) =
                            markdown_reference_destination(&line[closing + 2..])
                        {
                            definitions.push(MarkdownReferenceDefinition {
                                label,
                                destination: destination.to_string(),
                                line_start,
                                line_end,
                            });
                        }
                    }
                }
            }
        }
        line_start = line_end;
    }
    definitions
}

#[derive(Clone)]
struct MarkdownReferenceUse {
    label: String,
    start: usize,
    end: usize,
    is_image: bool,
}

fn markdown_reference_uses(
    text: &str,
    code_mask: &[bool],
    definitions: &[MarkdownReferenceDefinition],
    brackets: &MarkdownBracketPairs,
) -> Vec<MarkdownReferenceUse> {
    let bytes = text.as_bytes();
    let mut uses = Vec::new();
    let mut offset = 0;
    while offset < bytes.len() {
        if bytes[offset] != b'['
            || code_mask.get(offset).copied().unwrap_or_default()
            || is_markdown_escaped(text, offset)
            || definitions
                .iter()
                .any(|definition| (definition.line_start..definition.line_end).contains(&offset))
        {
            offset += 1;
            continue;
        }
        let Some(first_closing) = brackets.opening_to_closing.get(offset).copied().flatten() else {
            offset += 1;
            continue;
        };
        let first_label = normalize_markdown_reference_label(&text[offset + 1..first_closing]);
        let mut label = first_label.clone();
        let mut end = first_closing + 1;
        if bytes.get(end) == Some(&b'(') {
            offset = end;
            continue;
        }
        if bytes.get(end) == Some(&b'[') {
            let Some(second_closing) = brackets.opening_to_closing.get(end).copied().flatten()
            else {
                offset = end;
                continue;
            };
            let second_label = normalize_markdown_reference_label(&text[end + 1..second_closing]);
            if !second_label.is_empty() {
                label = second_label;
            }
            end = second_closing + 1;
        }
        if !label.is_empty()
            && definitions
                .iter()
                .any(|definition| definition.label == label)
        {
            let is_image =
                offset > 0 && bytes[offset - 1] == b'!' && !is_markdown_escaped(text, offset - 1);
            uses.push(MarkdownReferenceUse {
                label,
                start: if is_image { offset - 1 } else { offset },
                end,
                is_image,
            });
        }
        offset = end.max(offset + 1);
    }
    uses
}

fn markdown_link_syntax_mask(
    text: &str,
    code_mask: &[bool],
    definitions: &[MarkdownReferenceDefinition],
    reference_uses: &[MarkdownReferenceUse],
    brackets: &MarkdownBracketPairs,
) -> Vec<bool> {
    let mut mask = vec![false; text.len()];
    for (closing_label, _) in text.match_indices("](") {
        if code_mask.get(closing_label).copied().unwrap_or_default() {
            continue;
        }
        let Some((opening_label, is_image)) = brackets
            .closing_to_opening
            .get(closing_label)
            .copied()
            .flatten()
        else {
            continue;
        };
        let destination_start = closing_label + 2;
        if let Some(destination_length) =
            markdown_inline_destination_end(&text[destination_start..])
        {
            let start = if is_image {
                opening_label.saturating_sub(1)
            } else {
                opening_label
            };
            mask[start..destination_start + destination_length].fill(true);
        }
    }
    for reference in reference_uses {
        mask[reference.start..reference.end].fill(true);
    }
    for definition in definitions {
        mask[definition.line_start..definition.line_end].fill(true);
    }
    for (opening, _) in text.match_indices('<') {
        if code_mask.get(opening).copied().unwrap_or_default() || is_markdown_escaped(text, opening)
        {
            continue;
        }
        let Some(closing) = text[opening + 1..]
            .find('>')
            .map(|offset| opening + 1 + offset)
        else {
            continue;
        };
        let destination = &text[opening + 1..closing];
        if has_http_url_scheme(destination) && is_valid_markdown_autolink_destination(destination) {
            mask[opening..closing + 1].fill(true);
        }
    }
    mask
}

fn markdown_destination_matches_url(destination: &str, raw_url: &str, rendered_url: &str) -> bool {
    destination == raw_url
        || destination == rendered_url
        || markdown_link_destination(destination).as_deref() == Some(rendered_url)
}

fn contains_markdown_link_to_url_with_context(
    text: &str,
    raw_url: &str,
    rendered_url: &str,
    code_mask: &[bool],
    definitions: &[MarkdownReferenceDefinition],
    reference_uses: &[MarkdownReferenceUse],
    brackets: &MarkdownBracketPairs,
) -> bool {
    let has_inline_link = text.match_indices("](").any(|(offset, _)| {
        if code_mask.get(offset).copied().unwrap_or_default() {
            return false;
        }
        let Some((_, is_image)) = brackets.closing_to_opening.get(offset).copied().flatten() else {
            return false;
        };
        if is_image {
            return false;
        }
        let destination = &text[offset + 2..];
        destination
            .strip_prefix(rendered_url)
            .is_some_and(markdown_link_suffix_is_closed)
            || (is_valid_bare_markdown_destination(raw_url)
                && destination
                    .strip_prefix(raw_url)
                    .is_some_and(markdown_link_suffix_is_closed))
            || [raw_url, rendered_url].into_iter().any(|candidate| {
                destination
                    .strip_prefix('<')
                    .and_then(|rest| rest.strip_prefix(candidate))
                    .and_then(|rest| rest.strip_prefix('>'))
                    .is_some_and(markdown_link_suffix_is_closed)
            })
    });
    if has_inline_link {
        return true;
    }

    let has_reference_link = definitions.iter().any(|definition| {
        markdown_destination_matches_url(&definition.destination, raw_url, rendered_url)
            && reference_uses
                .iter()
                .any(|reference| !reference.is_image && reference.label == definition.label)
    });
    if has_reference_link {
        return true;
    }

    [raw_url, rendered_url].into_iter().any(|candidate| {
        if !is_valid_markdown_autolink_destination(candidate) {
            return false;
        }
        let autolink = format!("<{candidate}>");
        text.match_indices(&autolink).any(|(offset, _)| {
            !code_mask.get(offset).copied().unwrap_or_default()
                && !is_markdown_escaped(text, offset)
        })
    })
}

#[cfg(test)]
fn contains_markdown_link_to_url(text: &str, raw_url: &str, rendered_url: &str) -> bool {
    let code = markdown_code_scan(text);
    let definitions = markdown_reference_definitions(text, &code.mask);
    let brackets = markdown_bracket_pairs(text, &code.mask);
    let reference_uses = markdown_reference_uses(text, &code.mask, &definitions, &brackets);
    contains_markdown_link_to_url_with_context(
        text,
        raw_url,
        rendered_url,
        &code.mask,
        &definitions,
        &reference_uses,
        &brackets,
    )
}

pub(crate) fn text_with_url_citations(text: &str, annotations: &[Value]) -> String {
    struct Citation {
        start: Option<usize>,
        end: Option<usize>,
        raw_url: String,
        url: String,
        title: String,
    }

    let mut citations = Vec::new();
    for annotation in annotations {
        if annotation.get("type").and_then(Value::as_str) != Some("url_citation") {
            continue;
        }
        let Some(raw_url) = annotation.get("url").and_then(Value::as_str) else {
            continue;
        };
        let Some(url) = markdown_link_destination(raw_url) else {
            continue;
        };
        let title = annotation
            .get("title")
            .and_then(Value::as_str)
            .filter(|title| !title.trim().is_empty())
            .unwrap_or(raw_url)
            .to_string();
        let start = annotation
            .get("start_index")
            .and_then(Value::as_u64)
            .and_then(|index| usize::try_from(index).ok());
        let end = annotation
            .get("end_index")
            .and_then(Value::as_u64)
            .and_then(|index| usize::try_from(index).ok());
        citations.push(Citation {
            start,
            end,
            raw_url: raw_url.trim().to_string(),
            url,
            title,
        });
    }

    if citations.is_empty() {
        return text.to_string();
    }

    let code = markdown_code_scan(text);
    let definitions = markdown_reference_definitions(text, &code.mask);
    let brackets = markdown_bracket_pairs(text, &code.mask);
    let reference_uses = markdown_reference_uses(text, &code.mask, &definitions, &brackets);
    let link_syntax =
        markdown_link_syntax_mask(text, &code.mask, &definitions, &reference_uses, &brackets);
    let mut linked_urls = citations
        .iter()
        .filter(|citation| {
            contains_markdown_link_to_url_with_context(
                text,
                &citation.raw_url,
                &citation.url,
                &code.mask,
                &definitions,
                &reference_uses,
                &brackets,
            )
        })
        .map(|citation| citation.url.clone())
        .collect::<HashSet<_>>();
    let mut ranged = Vec::new();
    let mut fallback = Vec::new();
    for citation in citations {
        let Some((start, end)) = citation.start.zip(citation.end) else {
            fallback.push(citation);
            continue;
        };
        let Some(start) = char_index_to_byte_offset(text, start) else {
            fallback.push(citation);
            continue;
        };
        let Some(end) = char_index_to_byte_offset(text, end) else {
            fallback.push(citation);
            continue;
        };
        if start >= end
            || text[start..end].trim().is_empty()
            || text[start..end]
                .chars()
                .any(|character| character.is_whitespace() && character != ' ')
            || code.mask[start..end].iter().any(|masked| *masked)
            || (link_syntax[start..end].iter().any(|masked| *masked)
                && !linked_urls.contains(&citation.url))
        {
            fallback.push(citation);
            continue;
        }
        ranged.push((start, end, citation));
    }
    ranged.sort_by_key(|(start, end, _)| (*start, *end));

    let mut rendered = String::with_capacity(text.len());
    let mut cursor = 0;
    for (start, end, citation) in ranged {
        if start < cursor {
            fallback.push(citation);
            continue;
        }
        rendered.push_str(&text[cursor..start]);
        let cited_text = &text[start..end];
        if linked_urls.contains(&citation.url) {
            rendered.push_str(cited_text);
            cursor = end;
            continue;
        }
        rendered.push('[');
        rendered.push_str(&markdown_link_label(cited_text));
        rendered.push_str("](");
        rendered.push_str(&citation.url);
        rendered.push(')');
        cursor = end;
        linked_urls.insert(citation.url);
    }
    rendered.push_str(&text[cursor..]);

    let mut fallback_links = Vec::new();
    for citation in fallback {
        if !linked_urls.insert(citation.url.clone()) {
            continue;
        }
        fallback_links.push(format!(
            "[{}]({})",
            markdown_link_label(&citation.title),
            citation.url
        ));
    }
    if !fallback_links.is_empty() {
        if !rendered.is_empty() {
            if let Some((marker, length)) = code.unterminated_fence {
                if !rendered.ends_with('\n') {
                    rendered.push('\n');
                }
                rendered.extend(std::iter::repeat_n(char::from(marker), length));
                rendered.push_str("\n\n");
            } else {
                rendered.push_str("\n\n");
            }
        }
        rendered.push_str("Sources: ");
        rendered.push_str(&fallback_links.join(", "));
    }
    rendered
}

pub(crate) fn output_text_with_url_citations(block: &Value) -> Option<String> {
    let text = block
        .get("text")
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())?;
    let annotations = block
        .get("annotations")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    Some(text_with_url_citations(text, annotations))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn preserves_unicode_character_ranges() {
        let text = "查看 Rust 文档和 Cargo。";
        let annotations = json!([
            {"type":"url_citation","start_index":3,"end_index":7,
             "url":"https://www.rust-lang.org/","title":"Rust"},
            {"type":"url_citation","start_index":12,"end_index":17,
             "url":"https://doc.rust-lang.org/cargo/","title":"Cargo"}
        ]);
        assert_eq!(
            text_with_url_citations(text, annotations.as_array().unwrap()),
            "查看 [Rust](https://www.rust-lang.org/) 文档和 [Cargo](https://doc.rust-lang.org/cargo/)。"
        );
    }

    #[test]
    fn preserves_existing_link_to_same_url() {
        let existing_link = "([OpenAI docs](https://platform.openai.com/docs))";
        let text = format!("See {existing_link} for details.");
        let start_index = "See ".chars().count();
        let end_index = start_index + existing_link.chars().count();
        let annotations = json!([{
            "type":"url_citation","start_index":start_index,"end_index":end_index,
            "url":"https://platform.openai.com/docs","title":"OpenAI docs"
        }]);
        assert_eq!(
            text_with_url_citations(&text, annotations.as_array().unwrap()),
            text
        );
        assert!(contains_markdown_link_to_url(
            "[Docs](https://example.com/docs)",
            "https://example.com/docs",
            "https://example.com/docs"
        ));
    }

    #[test]
    fn escapes_untrusted_fallback_title() {
        let annotations = json!([{
            "type":"url_citation","url":"https://example.com/docs",
            "title":"<img src=x onerror=alert(1)>\nDocs"
        }]);
        assert_eq!(
            text_with_url_citations("Answer.", annotations.as_array().unwrap()),
            "Answer.\n\nSources: [&lt;img src\\=x onerror\\=alert\\(1\\)&gt; Docs](https://example.com/docs)"
        );
    }

    #[test]
    fn handles_code_fences_without_hiding_fallbacks() {
        let annotations = json!([{
            "type":"url_citation","url":"https://example.com/docs","title":"Docs"
        }]);
        assert_eq!(
            text_with_url_citations(
                "`[Docs](https://example.com/docs)`",
                annotations.as_array().unwrap()
            ),
            "`[Docs](https://example.com/docs)`\n\nSources: [Docs](https://example.com/docs)"
        );
        assert_eq!(
            text_with_url_citations("```text\npartial output", annotations.as_array().unwrap()),
            "```text\npartial output\n```\n\nSources: [Docs](https://example.com/docs)"
        );
    }

    #[test]
    fn avoids_nested_links_and_rejects_unsafe_urls() {
        let ranged = json!([{
            "type":"url_citation","start_index":1,"end_index":5,
            "url":"https://example.com/new","title":"New docs"
        }]);
        assert_eq!(
            text_with_url_citations(
                "[Docs](https://example.com/old)",
                ranged.as_array().unwrap()
            ),
            "[Docs](https://example.com/old)\n\nSources: [New docs](https://example.com/new)"
        );
        let fallback = json!([
            {"type":"url_citation","url":"https://example.com/docs_(latest)",
             "title":"Example [Docs]"},
            {"type":"url_citation","url":"javascript:alert(1)","title":"Unsafe"}
        ]);
        assert_eq!(
            text_with_url_citations("Answer.", fallback.as_array().unwrap()),
            "Answer.\n\nSources: [Example \\[Docs\\]](https://example.com/docs_%28latest%29)"
        );
    }
}
