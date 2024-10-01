/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#pragma once

#include <folly/container/F14Map.h>
#include <glog/logging.h>
#include "glean/rts/error.h"
#include "glean/rts/ownership.h"
#include "glean/rts/ownership/pool.h"

#include <cstdint>
#include <queue>
#include <vector>

namespace facebook {
namespace glean {
namespace rts {

/**
 * A datastructure which maps ranges of Ids to values. The current
 * implementation is a hack which only supports Ids which fit in 32 bits.
 *
 * The implementation is a bit trie with a large initial fanout (64k) and then a
 * smaller inner fanout (16), giving a maximum depth of 4 (for 32-bit values).
 *
 * This should most likely be switched to some form of Patricia tree.
 */
template <typename T>
class TrieArray {
 public:
  TrieArray() : trees_(new ForestN<FANOUT_TOP>(Tree::null())) {}

  /**
   * Insert a sorted sequence of non-overlapping Id ranges by combining the
   * previously stored values via `get`.
   *
   * This tries to split the tree as little as possible. We also guarantee to
   * call `get` exactly once for each previous value (including `nullptr` for
   * "no previous value").
   *
   * The trie maintains reference counts for each value, by calling
   *    value->use(uint_t)
   *
   * get(T* old_value, uint_t ref) -> T*
   *   `ref` references to `old_value` are being updated.
   *   get() is responsible for updating the refcount of the old value,
   *   and for releasing (or reusing) it to avoid leaking memory if
   *   its refcount would fall to zero.
   */
  template <typename Get>
  void insert(
      const OwnershipUnit::Ids* start,
      const OwnershipUnit::Ids* finish,
      Get&& get) {
    if (start == finish) {
      return;
    }

    minkey_ = std::min(minkey_, start->start.toWord());
    maxkey_ = std::max(maxkey_, finish[-1].finish.toWord());

    // only 32-bit keys are supported; this property is assumed later
    CHECK(maxkey_ <= std::numeric_limits<uint32_t>::max());

    // During insertion if we are replacing all references of an existing value,
    // we want to do that in a single operation so that get() can reuse
    // the memory for the old value.
    //
    // Algorithm:
    //
    // - Collect previously existing values in `values`.
    // - When we see a value for the first time, set its `link` field to point
    //   to the first `Tree` that contains it and add it to `values`.
    // - When we see a value again, temporarily make the current `Tree` point
    //   to the previous tree that contained the value (from the value's `link`)
    //   and update the value's `link` to point to the current tree. This
    //   effectively maintains a linked list of trees which contain a value,
    //   with the value's `link` being the root.
    // - Do the same for newly inserted trees which don't have a previous value
    //   via `null_link`.
    // - Once we've collected everything, for each value in `values` compute the
    //   new value via `get` and then traverse the linked list of trees, storing
    //   a pointer to the new value in each one.
    // - Do the same for `null_link`.
    std::vector<T*> values;
    Tree* null_link = nullptr;

    while (start != finish) {
      const auto [first_id, last_id] = *start++;
      if (first_id <= last_id) {
        traverse(
            first_id.toWord(),
            last_id.toWord() - first_id.toWord() + 1,
            [&](Tree& tree, uint64_t key, uint64_t size, size_t block) {
              if (size == block) {
                if (const auto value = tree.value()) {
                  const auto prev = static_cast<Tree*>(value->link());
                  value->link(&tree);
                  tree = Tree::link(prev);
                  if (prev == nullptr) {
                    values.push_back(value);
                  } else {
                    value->use(-1); // we dropped the ref from the trie
                  }
                } else {
                  tree = Tree::link(null_link);
                  null_link = &tree;
                }
              } else {
                if (auto value = tree.value()) {
                  value->use(FANOUT - 1);
                }
                tree = Tree::forest(pool_.alloc(tree));
              }
            });
      }
    }

    const auto unlink = [&](Tree* tree, T* FOLLY_NULLABLE value) {
      // If we are updating *all* references to this value, then the
      // refcount for the old value will be 1 here, and get() can do
      // an in-place update.
      auto upd = get(value, 1);
      uint32_t refs = 0;
      while (tree != nullptr) {
        auto next = tree->link();
        *tree = Tree::value(upd);
        tree = next;
        ++refs;
      }
      upd->use(refs - 1);
    };

    if (null_link) {
      unlink(null_link, nullptr);
    }

    for (auto value : values) {
      Tree* tree = static_cast<Tree*>(value->link());
      value->link(nullptr);
      unlink(tree, value);
    }
  }

  template <typename F>
  void foreach(F&& f) {
    traverse(
        [&](Tree& tree, uint64_t key, uint64_t size, uint64_t /* block */) {
          if (auto* value = tree.value()) {
            if (auto new_value = f(value)) {
              tree = Tree::value(new_value);
            }
          }
        });
  }

  struct Flattened {
    folly::F14FastMap<uint64_t, T*> sparse;
    std::vector<T*> dense;
  };

  /// Flatten the trie into:
  ///    - a dense array between start-end (end > maxkey_)
  ///    - a sparse mapping for elements less than start
  Flattened flatten(uint64_t start, uint64_t end) {
    if (end <= maxkey_) {
      error(
          "flatten: invalid bounds ({},{}) ({},{})",
          start,
          end,
          minkey_,
          maxkey_);
    }
    VLOG(1) << folly::sformat(
        "flatten: ({},{}) ({},{})", start, end, minkey_, maxkey_);

    // If there's no data in the tree, just return an empty result instead of
    // allocating an array of nullptr.
    if (maxkey_ <= minkey_) {
      return {};
    }

    folly::F14FastMap<uint64_t, T*> sparse;
    std::vector<T*> vec(end - start, nullptr);

    traverse(
        [&, start](
            const Tree& tree, uint64_t key, uint64_t size, uint64_t block) {
          auto* value = tree.value();
          if (value) {
            for (uint64_t i = key; i < std::min(key + size, start); i++) {
              sparse.insert({i, value});
            }
          }
          if (key + size > start) {
            const uint64_t left = key >= start ? key - start : 0;
            const uint64_t right = (key + size) - start;
            std::fill(vec.begin() + left, vec.begin() + right, value);
          }
          if (value) {
            value->use(size - 1);
          }
        });

    return {std::move(sparse), std::move(vec)};
  }

 private:
  static constexpr size_t FANOUT_TOP = 65536;
  static constexpr size_t FANOUT = 16;
  static constexpr size_t BLOCK =
      (size_t(std::numeric_limits<uint32_t>::max()) + 1) / FANOUT_TOP;

  static constexpr size_t blockSize(uint8_t level) {
    auto size = BLOCK;
    while (level != 0) {
      size /= FANOUT;
      --level;
    }
    return size;
  }

  template <uint32_t N>
  struct ForestN;
  using Forest = ForestN<FANOUT>;

  // A tagged pointer based sum of nothing (`nullptr`), a non-null pointer to a
  // value and a pointer to a forest.
  struct Tree {
    uintptr_t ptr;

    static Tree null() {
      Tree t;
      t.ptr = 0;
      return t;
    }

    static Tree value(T* x) {
      Tree t;
      t.ptr = reinterpret_cast<uintptr_t>(x);
      assert((t.ptr & 1) == 0);
      assert(t.ptr != 0);
      return t;
    }

    static Tree forest(Forest* forest) {
      Tree t;
      t.ptr = reinterpret_cast<uintptr_t>(forest);
      assert((t.ptr & 1) == 0);
      t.ptr |= 1;
      return t;
    }

    static Tree link(Tree* x) {
      Tree t;
      t.ptr = reinterpret_cast<uintptr_t>(x);
      return t;
    }

    bool empty() const {
      return ptr == 0;
    }

    T* FOLLY_NULLABLE value() const {
      return (ptr & 1) == 0 ? reinterpret_cast<T*>(ptr) : nullptr;
    }

    Forest* FOLLY_NULLABLE forest() {
      return (ptr & 1) == 1 ? reinterpret_cast<Forest*>(ptr - 1) : nullptr;
    }

    Tree* link() const {
      return reinterpret_cast<Tree*>(ptr);
    }

    bool isForest() const {
      return (ptr & 1) == 1;
    }
  };

  template <uint32_t N>
  struct ForestN {
    Tree trees_[N];

    explicit ForestN(Tree tree) {
      std::fill(trees_, trees_ + N, tree);
    }

    Tree& at(uint32_t i) {
      return trees_[i];
    }

    Tree at(uint32_t i) const {
      return trees_[i];
    }
  };

  static std::pair<uint64_t, uint64_t> location(uint64_t key) {
    assert(key <= std::numeric_limits<uint32_t>::max());
    return {key / BLOCK, key % BLOCK};
  }

  template <typename F>
  void traverse(F&& f) {
    if (minkey_ <= maxkey_) {
      traverse(minkey_, maxkey_ - minkey_ + 1, f);
    }
  }

  // NOTE: We traverse the tree via type-level recursion rather than a runtime
  // loop since there is a very small, statically knows bound on its depth.
  //
  // `F` gets called for each leaf tree (with or without a value). It can modify
  // the tree to become a forest in which case `traverse` will descend into it.
  template <typename F>
  void traverse(uint64_t start, uint64_t size, F&& f) {
    auto [first_block, first_index] = location(start);
    auto [last_block, last_index] = location(start + (size - 1));

    uint64_t key = start;
    while (first_block < last_block) {
      const auto n = BLOCK - first_index;
      traverse<0>(trees_->at(first_block), key, first_index, n, f);
      key += n;
      ++first_block;
      first_index = 0;
    }
    traverse<0>(
        trees_->at(first_block),
        key,
        first_index,
        last_index - first_index + 1,
        f);
  }

  template <size_t level, typename F>
  static void
  traverse(Tree& tree, uint64_t key, uint64_t start, uint64_t size, F& f) {
    if (!tree.isForest()) {
      f(tree, key, size, blockSize(level));
    }
    if (auto forest = tree.forest()) {
      constexpr auto block = blockSize(level + 1);
      if constexpr (block != 0) {
        auto t = start / block;
        auto i = start % block;
        while (size != 0) {
          const auto n = std::min(size, block - i);
          traverse<level + 1>(forest->at(t), key, i, n, f);
          i = 0;
          key += n;
          size -= n;
          ++t;
        }
      }
    }
  }

  std::unique_ptr<ForestN<FANOUT_TOP>> trees_;
  Pool<Forest> pool_;
  uint64_t minkey_ = std::numeric_limits<uint64_t>::max();
  uint64_t maxkey_ = 0;
};

} // namespace rts
} // namespace glean
} // namespace facebook
