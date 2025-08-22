/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#include "glean/client/swift/GlassAccess.h"
#include <folly/ExceptionString.h>
#include <folly/String.h>
#include <folly/coro/BlockingWait.h>
#include <glog/logging.h>
#include <memory>
#include <stdexcept>
#include "glean/client/swift/Clock.h"
#include "glean/client/swift/hash.h"

using namespace facebook;
using apache::thrift::RpcOptions;

const auto GlassTimeoutMs = 900;

GlassAccess::GlassAccess() : client(nullptr), hgRoot_(getHgRoot()) {}

folly::coro::Task<std::optional<protocol::LocationList>>
GlassAccess::usrToDefinition(
    const std::string usr,
    const std::optional<std::string> revision) {
  std::string msg;

  // Check if this is a Swift USR (starts with "s:")
  if (usr.length() >= 2 && usr.substr(0, 2) == "s:") {
    // Handle Swift USR using usrToDefinition
    co_return co_await handleUSR(usr, revision, msg);
  } else {
    // Handle non-Swift USR using clangUSRToDefinition with hash
    co_return co_await handleUSRHash(usr, revision, msg);
  }
}

folly::coro::Task<std::optional<protocol::LocationList>> GlassAccess::handleUSR(
    const std::string usr,
    const std::optional<std::string> revision,
    std::string& msg) {
  // Create USRToDefinitionRequest
  ::glean::USRToDefinitionRequest request;
  request.usr() = usr;
  request.repo_name() = "fbsource";

  // Call the Glass service to get symbol definition
  const auto result =
      co_await this->runGlassMethod<::glean::USRSymbolDefinition>(
          "usrToDefinition",
          msg,
          [&]() -> folly::coro::Task<::glean::USRSymbolDefinition> {
            ::glean::RequestOptions ro;
            // Set revision if provided
            if (revision.has_value()) {
              ro.revision_ref() = revision.value();
            }
            RpcOptions rpcOptions;
            rpcOptions.setTimeout(std::chrono::milliseconds(GlassTimeoutMs));
            co_return co_await client->co_usrToDefinition(
                rpcOptions, request, ro);
          });

  if (!result.has_value()) {
    co_return std::nullopt;
  }

  co_return convertUSRSymbolDefinitionToLocations(result.value());
}

folly::coro::Task<std::optional<protocol::LocationList>>
GlassAccess::handleUSRHash(
    const std::string usr,
    const std::optional<std::string> revision,
    std::string& msg) {
  // Hash the USR for clang USR lookup
  std::string hashedUSR = facebook::glean::clangx::hash::hash(usr);

  // Call the Glass service using clangUSRToDefinition
  const auto result =
      co_await this->runGlassMethod<::glean::USRSymbolDefinition>(
          "clangUSRToDefinition",
          msg,
          [&]() -> folly::coro::Task<::glean::USRSymbolDefinition> {
            ::glean::RequestOptions ro;
            // Set revision if provided
            if (revision.has_value()) {
              ro.revision_ref() = revision.value();
            }
            RpcOptions rpcOptions;
            rpcOptions.setTimeout(std::chrono::milliseconds(GlassTimeoutMs));
            co_return co_await client->co_clangUSRToDefinition(
                rpcOptions, hashedUSR, ro);
          });

  if (!result.has_value()) {
    co_return std::nullopt;
  }

  co_return convertUSRSymbolDefinitionToLocations(result.value());
}

protocol::LocationList GlassAccess::convertUSRSymbolDefinitionToLocations(
    const ::glean::USRSymbolDefinition& definition) const {
  // Convert Glass result to protocol::LocationList
  protocol::LocationList locations;

  // Extract location from USRSymbolDefinition
  const auto& gleanLocation = definition.location().value();

  // Convert glean::LocationRange to protocol::Location
  // Access the range fields directly
  const auto& range = gleanLocation.range().value();

  protocol::Position start(
      static_cast<int>(range.lineBegin().value()),
      static_cast<int>(range.columnBegin().value()));
  protocol::Position end(
      static_cast<int>(range.lineEnd().value()),
      static_cast<int>(range.columnEnd().value()));
  protocol::Range protocolRange(start, end);

  // Create URI from repository and filepath using URI escaping
  std::string filepath = hgRoot_ + "/" + gleanLocation.filepath().value();
  std::string uri = "file://" + folly::uriEscape<std::string>(filepath);
  protocol::Location location(uri, protocolRange);

  locations.push_back(location);

  return locations;
}

template <typename T>
folly::coro::Task<std::optional<T>> GlassAccess::runGlassMethod(
    const std::string method,
    std::string& msg,
    folly::Function<folly::coro::Task<T>()> f) {
  try {
    co_return std::make_optional(co_await f());
  } catch (::glean::ServerException& ex) {
    msg += "::glean::ServerException(" + ex.message().value() + ");";
    LOG(ERROR) << "EXCEPTION searching " << msg << "\n";
  } catch (std::exception& ex) {
    msg += folly::exceptionStr(ex) + ";";
    LOG(ERROR) << "EXCEPTION running " << method << ":" << ex.what() << ":"
               << msg << "\n";
  }
  co_return {};
}

std::string GlassAccess::getHgRoot() {
  // Execute 'hg root' command to get the mercurial repository root
  FILE* pipe = popen("hg root", "r");
  if (!pipe) {
    throw std::runtime_error("Failed to execute 'hg root' command");
  }

  char buffer[1024];
  std::string result;
  while (fgets(buffer, sizeof(buffer), pipe) != nullptr) {
    result += buffer;
  }

  int status = pclose(pipe);
  if (status != 0) {
    throw std::runtime_error(
        "'hg root' command failed with status: " + std::to_string(status));
  }

  // Remove trailing newline if present
  if (!result.empty() && result.back() == '\n') {
    result.pop_back();
  }

  if (result.empty()) {
    throw std::runtime_error("'hg root' command returned empty result");
  }

  return result;
}

folly::coro::Task<void> GlassAccess::warmUpConnection() {
  facebook::glean::swift::Clock clock;

  LOG(INFO) << "Warming up Glass connection...";

  try {
    // Use getStatus to establish the connection
    std::string msg;

    // Call the Glass service getStatus
    co_await this->runGlassMethod<fb303::cpp2::fb_status>(
        "getStatus", msg, [&]() -> folly::coro::Task<fb303::cpp2::fb_status> {
          RpcOptions rpcOptions;
          rpcOptions.setTimeout(std::chrono::milliseconds(GlassTimeoutMs));
          co_return co_await client->co_getStatus(rpcOptions);
        });

    auto duration = clock.duration();

    LOG(INFO) << "Glass connection established successfully in " << duration
              << " milliseconds";
  } catch (const std::exception& e) {
    auto duration = clock.duration();

    LOG(WARNING) << "Glass connection warm-up failed after " << duration
                 << " milliseconds: " << e.what();
  }
}
