/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

//! SCIP symbol parsing according to the specification at third-party/scip/scip.proto
//!
//! This module handles parsing of SCIP symbols, which follow the format:
//! - Local symbols: `local <local-id>`
//! - Global symbols: `<scheme> <manager> <package-name> <version> <descriptors>+`
//!
//! Key features:
//! - Handles escaped identifiers (backtick-enclosed with double-backtick escaping)
//! - Parses all descriptor types (namespace, type, term, method, parameter, etc.)
//! - Supports the "." placeholder for empty package fields

#[allow(dead_code)]
pub enum ScipSymbol {
    Local {
        id: String,
    },
    Global {
        scheme: String,
        package: Package,
        descriptors: Vec<Descriptor>,
    },
}

#[allow(dead_code)]
pub struct Package {
    pub manager: Option<String>,
    pub name: Option<String>,
    pub version: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Descriptor {
    pub name: String,
    pub kind: DescriptorKind,
}

#[derive(Debug, Clone, PartialEq)]
pub enum DescriptorKind {
    Namespace,              // name/
    Type,                   // name#
    Term,                   // name.
    Method(Option<String>), // name(<disambiguator>?).
    TypeParameter,          // [name]
    Parameter,              // (name)
    Meta,                   // name:
    Macro,                  // name!
}

/// Parses a SCIP symbol string according to the SCIP specification.
///
/// # Format
/// Symbols follow this format:
/// - Local: `local <local-id>`
/// - Global: `<scheme> <manager> <package-name> <version> <descriptors>+`
///
/// Where:
/// - Spaces in scheme/manager/package-name/version are escaped with double spaces
/// - Single spaces delimit fields
/// - "." is used as a placeholder for empty values in package fields
/// - Descriptors can be: namespace (/), type (#), term (.), method ((.).),
///   type-parameter ([]), parameter (()), meta (:), or macro (!)
///
/// # Examples
/// ```
/// use scip_symbol::parse_scip_symbol;
///
/// let symbol = "rust-analyzer cargo std v1.0 io/IsTerminal#";
/// let parsed = parse_scip_symbol(symbol);
/// ```
pub fn parse_scip_symbol(symbol: &str) -> ScipSymbol {
    // Handle local symbols: "local <local-id>"
    if let Some(("local", rest)) = symbol.split_once(' ') {
        return ScipSymbol::Local {
            id: rest.to_string(),
        };
    }

    // Parse global symbols: "<scheme> <manager> <package-name> <version> <descriptors>+"
    // Each field is space-escaped (double spaces represent single spaces)
    // Single spaces delimit fields

    let (scheme, rest) = parse_space_escaped_field(symbol);
    let (manager, rest) = parse_space_escaped_field(rest);
    let (pkgname, rest) = parse_space_escaped_field(rest);
    let (version, descriptors_str) = parse_space_escaped_field(rest);

    // Convert "." placeholder to None according to SCIP spec
    let package = Package {
        manager: if manager == "." { None } else { Some(manager) },
        name: if pkgname == "." { None } else { Some(pkgname) },
        version: if version == "." { None } else { Some(version) },
    };

    let descriptors = parse_descriptors(descriptors_str);

    ScipSymbol::Global {
        scheme,
        package,
        descriptors,
    }
}

/// Parses a space-escaped field according to SCIP spec.
///
/// According to the SCIP spec, spaces in scheme/manager/package-name/version
/// are escaped with double spaces. This function:
/// 1. Reads until it finds a single space (field delimiter)
/// 2. Converts double spaces to single spaces in the result
///
/// Returns (field, remaining_string)
fn parse_space_escaped_field(s: &str) -> (String, &str) {
    let bytes = s.as_bytes();
    let mut i = 0;

    while i < bytes.len() {
        if bytes[i] == b' ' {
            // Check if this is a double space (escaped space)
            if i + 1 < bytes.len() && bytes[i + 1] == b' ' {
                // Skip both spaces (this is an escaped space within the field)
                i += 2;
            } else {
                // Single space - this is the field delimiter
                return (unescape_spaces(&s[..i]), &s[i + 1..]);
            }
        } else {
            i += 1;
        }
    }

    // No delimiter found, return entire string
    (s.to_string(), "")
}

/// Unescapes double spaces in a string field.
///
/// According to SCIP spec, double spaces in scheme/manager/package-name/version
/// represent a single space character.
fn unescape_spaces(s: &str) -> String {
    s.replace("  ", " ")
}

/// Parses an identifier, handling both simple and escaped identifiers.
///
/// According to SCIP spec:
/// - Simple identifiers: contain only '_', '+', '-', '$', or alphanumeric chars
/// - Escaped identifiers: surrounded by backticks, backticks escaped as ``
///
/// Returns (unescaped_name, bytes_consumed)
fn parse_identifier(s: &str, start: usize) -> (String, usize) {
    let bytes = s.as_bytes();

    if start < bytes.len() && bytes[start] == b'`' {
        // Escaped identifier: parse until closing backtick
        let mut i = start + 1;
        let mut result = String::new();

        while i < bytes.len() {
            if bytes[i] == b'`' {
                // Check if this is a double backtick (escaped backtick)
                if i + 1 < bytes.len() && bytes[i + 1] == b'`' {
                    // Escaped backtick - add single backtick to result
                    result.push('`');
                    i += 2;
                } else {
                    // End of escaped identifier
                    return (result, i + 1 - start);
                }
            } else {
                // Regular character
                result.push(bytes[i] as char);
                i += 1;
            }
        }

        // If we get here, no closing backtick was found
        // Return what we have and consume to end
        (result, i - start)
    } else {
        // Simple identifier: parse until we hit a non-identifier character
        let mut i = start;
        while i < bytes.len() {
            let c = bytes[i];
            match c {
                b'_' | b'+' | b'-' | b'$' | b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' => {
                    i += 1;
                }
                _ => break,
            }
        }

        // Return the slice directly (no unescaping needed for simple identifiers)
        (s[start..i].to_string(), i - start)
    }
}

/// Parses a type parameter descriptor: [name]
///
/// Returns (descriptor, new_position)
fn parse_type_parameter(descriptors_str: &str, start_pos: usize) -> (Descriptor, usize) {
    let bytes = descriptors_str.as_bytes();
    let mut i = start_pos + 1; // Skip '['

    let (name, consumed) = parse_identifier(descriptors_str, i);
    i += consumed;

    // Skip to ']'
    while i < bytes.len() && bytes[i] != b']' {
        i += 1;
    }
    i += 1; // Skip ']'

    (
        Descriptor {
            name,
            kind: DescriptorKind::TypeParameter,
        },
        i,
    )
}

/// Parses a parameter descriptor: (name)
///
/// Returns (descriptor, new_position)
fn parse_parameter(descriptors_str: &str, start_pos: usize) -> (Descriptor, usize) {
    let bytes = descriptors_str.as_bytes();
    let mut i = start_pos + 1; // Skip '('

    let (name, consumed) = parse_identifier(descriptors_str, i);
    i += consumed;

    // Skip to ')'
    while i < bytes.len() && bytes[i] != b')' {
        i += 1;
    }
    i += 1; // Skip ')'

    (
        Descriptor {
            name,
            kind: DescriptorKind::Parameter,
        },
        i,
    )
}

/// Parses a method descriptor: name(<disambiguator>?).
///
/// Returns (descriptor, new_position)
fn parse_method(descriptors_str: &str, name: String, start_pos: usize) -> (Descriptor, usize) {
    let bytes = descriptors_str.as_bytes();
    let mut i = start_pos + 1; // Skip '('

    let disambiguator_start = i;
    while i < bytes.len() && bytes[i] != b')' {
        i += 1;
    }
    let disambiguator_end = i;

    let disambiguator = if disambiguator_start == disambiguator_end {
        None
    } else {
        Some(descriptors_str[disambiguator_start..disambiguator_end].to_string())
    };

    i += 1; // Skip ')'
    if i < bytes.len() && bytes[i] == b'.' {
        i += 1; // Skip '.'
    }

    (
        Descriptor {
            name,
            kind: DescriptorKind::Method(disambiguator),
        },
        i,
    )
}

/// Parses a simple descriptor with a single-char suffix: /, #, ., :, or !
///
/// Returns (descriptor, new_position)
fn parse_simple_descriptor(name: String, suffix_char: u8, pos: usize) -> (Descriptor, usize) {
    let kind = match suffix_char {
        b'/' => DescriptorKind::Namespace,
        b'#' => DescriptorKind::Type,
        b'.' => DescriptorKind::Term,
        b':' => DescriptorKind::Meta,
        b'!' => DescriptorKind::Macro,
        _ => unreachable!(),
    };

    // For macros, include the '!' in the name
    let final_name = if matches!(kind, DescriptorKind::Macro) {
        format!("{}!", name)
    } else {
        name
    };

    (
        Descriptor {
            name: final_name,
            kind,
        },
        pos + 1, // Skip suffix
    )
}

/// Parses a chain of SCIP descriptors from a descriptor string.
///
/// Returns a vector of all descriptors found in the string.
fn parse_descriptors(descriptors_str: &str) -> Vec<Descriptor> {
    if descriptors_str.is_empty() {
        return Vec::new();
    }

    let mut result = Vec::new();
    let bytes = descriptors_str.as_bytes();
    let mut i = 0;

    while i < bytes.len() {
        if bytes[i] == b'[' {
            // Type parameter: [name]
            let (descriptor, new_pos) = parse_type_parameter(descriptors_str, i);
            result.push(descriptor);
            i = new_pos;
        } else if bytes[i] == b'(' {
            // Parameter: (name)
            let (descriptor, new_pos) = parse_parameter(descriptors_str, i);
            result.push(descriptor);
            i = new_pos;
        } else {
            // Regular descriptor: name followed by a single-char suffix or method
            let start = i;
            let (name, consumed) = parse_identifier(descriptors_str, start);
            i = start + consumed;

            if i < bytes.len() {
                let c = bytes[i];
                match c {
                    b'/' | b'#' | b'.' | b':' | b'!' => {
                        let (descriptor, new_pos) = parse_simple_descriptor(name, c, i);
                        result.push(descriptor);
                        i = new_pos;
                    }
                    b'(' => {
                        // Method: name(<disambiguator>?).
                        let (descriptor, new_pos) = parse_method(descriptors_str, name, i);
                        result.push(descriptor);
                        i = new_pos;
                    }
                    _ => {
                        // No recognized suffix, skip
                        i += 1;
                    }
                }
            }
        }
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_symbol_from_string_global_type() {
        let symbol = "rust-analyzer cargo std https://github.com/rust-lang/rust/library/std io/stdio/IsTerminal#";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global {
            scheme,
            package,
            descriptors,
        } = symbol
        else {
            panic!("expected global symbol");
        };

        assert_eq!(scheme, "rust-analyzer");
        assert_eq!(package.manager, Some("cargo".to_string()));
        assert_eq!(package.name, Some("std".to_string()));
        assert_eq!(
            package.version,
            Some("https://github.com/rust-lang/rust/library/std".to_string())
        );

        assert_eq!(descriptors.len(), 3);
        assert_eq!(descriptors[0].name, "io");
        assert_eq!(descriptors[0].kind, DescriptorKind::Namespace);
        assert_eq!(descriptors[1].name, "stdio");
        assert_eq!(descriptors[1].kind, DescriptorKind::Namespace);
        assert_eq!(descriptors[2].name, "IsTerminal");
        assert_eq!(descriptors[2].kind, DescriptorKind::Type);
    }

    #[test]
    fn test_symbol_from_string_global_unspecified() {
        let symbol =
            "rust-analyzer cargo std https://github.com/rust-lang/rust/library/std macros/println!";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global {
            scheme,
            package,
            descriptors,
        } = symbol
        else {
            panic!("expected global symbol");
        };

        assert_eq!(scheme, "rust-analyzer");
        assert_eq!(package.manager, Some("cargo".to_string()));
        assert_eq!(package.name, Some("std".to_string()));
        assert_eq!(
            package.version,
            Some("https://github.com/rust-lang/rust/library/std".to_string())
        );

        assert_eq!(descriptors.len(), 2);
        assert_eq!(descriptors[0].name, "macros");
        assert_eq!(descriptors[0].kind, DescriptorKind::Namespace);
        assert_eq!(descriptors[1].name, "println!");
        assert_eq!(descriptors[1].kind, DescriptorKind::Macro);
    }

    #[test]
    fn test_symbol_from_string_method() {
        // Test method with no disambiguator
        let symbol = "scip . . . MyClass#myMethod().";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global { descriptors, .. } = symbol else {
            panic!("expected global symbol");
        };

        assert_eq!(descriptors.len(), 2);
        assert_eq!(descriptors[0].name, "MyClass");
        assert_eq!(descriptors[0].kind, DescriptorKind::Type);
        assert_eq!(descriptors[1].name, "myMethod");
        assert_eq!(descriptors[1].kind, DescriptorKind::Method(None));
    }

    #[test]
    fn test_symbol_from_string_type_parameter() {
        let symbol = "scip . . . List#[T]";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global { descriptors, .. } = symbol else {
            panic!("expected global symbol");
        };

        assert_eq!(descriptors.len(), 2);
        assert_eq!(descriptors[0].name, "List");
        assert_eq!(descriptors[0].kind, DescriptorKind::Type);
        assert_eq!(descriptors[1].name, "T");
        assert_eq!(descriptors[1].kind, DescriptorKind::TypeParameter);
    }

    #[test]
    fn test_symbol_from_string_parameter() {
        let symbol = "scip . . . func().(param)";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global { descriptors, .. } = symbol else {
            panic!("expected global symbol");
        };

        assert_eq!(descriptors.len(), 2);
        assert_eq!(descriptors[0].name, "func");
        assert_eq!(descriptors[0].kind, DescriptorKind::Method(None));
        assert_eq!(descriptors[1].name, "param");
        assert_eq!(descriptors[1].kind, DescriptorKind::Parameter);
    }

    #[test]
    fn test_symbol_from_string_term() {
        let symbol = "scip . . . package/MyClass.field.";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global { descriptors, .. } = symbol else {
            panic!("expected global symbol");
        };

        assert_eq!(descriptors.len(), 3);
        assert_eq!(descriptors[0].name, "package");
        assert_eq!(descriptors[0].kind, DescriptorKind::Namespace);
        assert_eq!(descriptors[1].name, "MyClass");
        assert_eq!(descriptors[1].kind, DescriptorKind::Term);
        assert_eq!(descriptors[2].name, "field");
        assert_eq!(descriptors[2].kind, DescriptorKind::Term);
    }

    #[test]
    fn test_symbol_from_string_meta() {
        let symbol = "scip . . . annotation:";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global { descriptors, .. } = symbol else {
            panic!("expected global symbol");
        };

        assert_eq!(descriptors.len(), 1);
        assert_eq!(descriptors[0].name, "annotation");
        assert_eq!(descriptors[0].kind, DescriptorKind::Meta);
    }

    #[test]
    fn test_symbol_from_string_local() {
        let symbol = "local myVar";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Local { id } = symbol else {
            panic!("expected local symbol");
        };

        assert_eq!(id, "myVar");
    }

    #[test]
    fn test_symbol_from_string_package_placeholder() {
        // Test that "." is converted to None for package fields
        let symbol = "rust-analyzer . . . io/stdio/IsTerminal#";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global { package, .. } = symbol else {
            panic!("expected global symbol");
        };

        assert_eq!(package.manager, None);
        assert_eq!(package.name, None);
        assert_eq!(package.version, None);
    }

    #[test]
    fn test_escaped_identifier_simple() {
        // Test escaped identifier with space
        let symbol = "scip . . . `has space`/";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global { descriptors, .. } = symbol else {
            panic!("expected global symbol");
        };

        assert_eq!(descriptors.len(), 1);
        assert_eq!(descriptors[0].name, "has space");
        assert_eq!(descriptors[0].kind, DescriptorKind::Namespace);
    }

    #[test]
    fn test_escaped_identifier_with_backticks() {
        // Test escaped identifier with backticks (double backtick escaping)
        let symbol = "scip . . . `name``with``backticks`#";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global { descriptors, .. } = symbol else {
            panic!("expected global symbol");
        };

        assert_eq!(descriptors.len(), 1);
        assert_eq!(descriptors[0].name, "name`with`backticks");
        assert_eq!(descriptors[0].kind, DescriptorKind::Type);
    }

    #[test]
    fn test_escaped_identifier_method() {
        // Test escaped identifier in method name
        let symbol = "scip . . . MyClass#`special method`().";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global { descriptors, .. } = symbol else {
            panic!("expected global symbol");
        };

        assert_eq!(descriptors.len(), 2);
        assert_eq!(descriptors[0].name, "MyClass");
        assert_eq!(descriptors[0].kind, DescriptorKind::Type);
        assert_eq!(descriptors[1].name, "special method");
        assert_eq!(descriptors[1].kind, DescriptorKind::Method(None));
    }

    #[test]
    fn test_method_with_disambiguator() {
        // Test method with disambiguator
        let symbol = "scip . . . MyClass#myMethod(disambig).";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global { descriptors, .. } = symbol else {
            panic!("expected global symbol");
        };

        assert_eq!(descriptors.len(), 2);
        assert_eq!(descriptors[0].name, "MyClass");
        assert_eq!(descriptors[0].kind, DescriptorKind::Type);
        assert_eq!(descriptors[1].name, "myMethod");
        assert_eq!(
            descriptors[1].kind,
            DescriptorKind::Method(Some("disambig".to_string()))
        );
    }

    #[test]
    fn test_space_escaped_scheme() {
        // Test scheme with space (escaped as double space)
        let symbol = "my  scheme cargo pkg v1.0 MyClass#";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global {
            scheme, package, ..
        } = symbol
        else {
            panic!("expected global symbol");
        };

        assert_eq!(scheme, "my scheme");
        assert_eq!(package.manager, Some("cargo".to_string()));
        assert_eq!(package.name, Some("pkg".to_string()));
        assert_eq!(package.version, Some("v1.0".to_string()));
    }

    #[test]
    fn test_space_escaped_manager() {
        // Test manager with space (escaped as double space)
        let symbol = "scip my  manager pkg v1.0 MyClass#";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global { package, .. } = symbol else {
            panic!("expected global symbol");
        };

        assert_eq!(package.manager, Some("my manager".to_string()));
        assert_eq!(package.name, Some("pkg".to_string()));
        assert_eq!(package.version, Some("v1.0".to_string()));
    }

    #[test]
    fn test_space_escaped_package_name() {
        // Test package name with space (escaped as double space)
        let symbol = "scip cargo my  package v1.0 MyClass#";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global { package, .. } = symbol else {
            panic!("expected global symbol");
        };

        assert_eq!(package.manager, Some("cargo".to_string()));
        assert_eq!(package.name, Some("my package".to_string()));
        assert_eq!(package.version, Some("v1.0".to_string()));
    }

    #[test]
    fn test_space_escaped_version() {
        // Test version with space (escaped as double space)
        let symbol = "scip cargo pkg v1.0  beta MyClass#";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global { package, .. } = symbol else {
            panic!("expected global symbol");
        };

        assert_eq!(package.manager, Some("cargo".to_string()));
        assert_eq!(package.name, Some("pkg".to_string()));
        assert_eq!(package.version, Some("v1.0 beta".to_string()));
    }

    #[test]
    fn test_multiple_space_escapes() {
        // Test multiple spaces in multiple fields
        let symbol = "my  scheme my  manager my  package my  version MyClass#";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global {
            scheme, package, ..
        } = symbol
        else {
            panic!("expected global symbol");
        };

        assert_eq!(scheme, "my scheme");
        assert_eq!(package.manager, Some("my manager".to_string()));
        assert_eq!(package.name, Some("my package".to_string()));
        assert_eq!(package.version, Some("my version".to_string()));
    }

    #[test]
    fn test_space_escapes_multiple_spaces() {
        // Test multiple consecutive spaces (4 spaces = 2 spaces in result)
        let symbol = "my    scheme cargo pkg v1.0 MyClass#";
        let symbol = parse_scip_symbol(symbol);
        let ScipSymbol::Global { scheme, .. } = symbol else {
            panic!("expected global symbol");
        };

        assert_eq!(scheme, "my  scheme");
    }

    #[test]
    fn test_rubbish_objc() {
        // Test multiple consecutive spaces (4 spaces = 2 spaces in result)
        let symbol_str = "c:(cm)ArtemisMockDeviceScanner_get_interface_plugin_MockDeviceScanners";
        let symbol = parse_scip_symbol(symbol_str);
        let ScipSymbol::Global { scheme, .. } = symbol else {
            panic!("expected global symbol");
        };
        assert_eq!(scheme, symbol_str);
    }

    #[test]
    fn test_rubbish_swift() {
        // Test multiple consecutive spaces (4 spaces = 2 spaces in result)
        let symbol_str = "s:010ContactRowA10CacheTestsAAC04msgrA013FWAShareSheet0A4InfoVvg";
        let symbol = parse_scip_symbol(symbol_str);
        let ScipSymbol::Global { scheme, .. } = symbol else {
            panic!("expected global symbol");
        };
        assert_eq!(scheme, symbol_str);
    }
}
