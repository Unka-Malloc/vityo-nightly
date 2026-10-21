//! Bounded LRU materialization cache indexed by revision and resource.

use std::collections::{BTreeMap, HashMap, HashSet};

#[derive(Clone, Debug, Hash, PartialEq, Eq)]
pub struct ContextCacheKey {
    pub evidence_id: String,
    pub resource: String,
    pub revision: u64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ContextCacheMetrics {
    pub hits: u64,
    pub misses: u64,
    pub evictions: u64,
}

pub struct ContextCache {
    max_entries: usize,
    max_bytes: usize,
    byte_count: usize,
    next_order: u64,
    entries: HashMap<ContextCacheKey, CacheEntry>,
    lru: BTreeMap<u64, ContextCacheKey>,
    by_resource: HashMap<String, HashSet<ContextCacheKey>>,
    metrics: ContextCacheMetrics,
}

impl ContextCache {
    pub fn new(max_entries: usize, max_bytes: usize) -> Self {
        Self {
            max_entries,
            max_bytes,
            byte_count: 0,
            next_order: 0,
            entries: HashMap::new(),
            lru: BTreeMap::new(),
            by_resource: HashMap::new(),
            metrics: ContextCacheMetrics::default(),
        }
    }

    pub fn entry_count(&self) -> usize {
        self.entries.len()
    }

    pub fn byte_count(&self) -> usize {
        self.byte_count
    }

    pub fn metrics(&self) -> ContextCacheMetrics {
        self.metrics
    }

    pub fn get(&mut self, key: &ContextCacheKey) -> Option<&str> {
        let Some(old_order) = self.entries.get(key).map(|entry| entry.order) else {
            self.metrics.misses = self.metrics.misses.saturating_add(1);
            return None;
        };
        self.lru.remove(&old_order);
        let order = self.allocate_order();
        self.lru.insert(order, key.clone());
        let entry = self.entries.get_mut(key).expect("entry was just observed");
        entry.order = order;
        self.metrics.hits = self.metrics.hits.saturating_add(1);
        Some(&entry.value)
    }

    pub fn put(&mut self, key: ContextCacheKey, value: String) {
        let byte_count = value.len();
        self.remove(&key);
        if self.max_entries == 0 || byte_count > self.max_bytes {
            return;
        }
        let order = self.allocate_order();
        self.byte_count += byte_count;
        self.by_resource
            .entry(key.resource.clone())
            .or_default()
            .insert(key.clone());
        self.lru.insert(order, key.clone());
        self.entries.insert(
            key,
            CacheEntry {
                value,
                byte_count,
                order,
            },
        );
        while self.entries.len() > self.max_entries || self.byte_count > self.max_bytes {
            let Some((order, oldest)) = self.lru.first_key_value() else {
                break;
            };
            let (order, oldest) = (*order, oldest.clone());
            self.lru.remove(&order);
            if self.remove_entry(&oldest).is_some() {
                self.metrics.evictions = self.metrics.evictions.saturating_add(1);
            }
        }
    }

    /// Remove only entries from this resource whose revision is no longer
    /// current. Resource indexing keeps invalidation proportional to that
    /// resource's cached entries rather than the entire cache.
    pub fn invalidate_resource(&mut self, resource: &str, current_revision: u64) {
        let stale = self
            .by_resource
            .get(resource)
            .into_iter()
            .flat_map(|keys| keys.iter())
            .filter(|key| key.revision != current_revision)
            .cloned()
            .collect::<Vec<_>>();
        for key in stale {
            self.remove(&key);
        }
    }

    fn allocate_order(&mut self) -> u64 {
        let order = self.next_order;
        self.next_order = self.next_order.saturating_add(1);
        order
    }

    fn remove(&mut self, key: &ContextCacheKey) -> Option<CacheEntry> {
        let entry = self.remove_entry(key)?;
        self.lru.remove(&entry.order);
        Some(entry)
    }

    fn remove_entry(&mut self, key: &ContextCacheKey) -> Option<CacheEntry> {
        let entry = self.entries.remove(key)?;
        self.byte_count -= entry.byte_count;
        if let Some(keys) = self.by_resource.get_mut(&key.resource) {
            keys.remove(key);
            if keys.is_empty() {
                self.by_resource.remove(&key.resource);
            }
        }
        Some(entry)
    }
}

struct CacheEntry {
    value: String,
    byte_count: usize,
    order: u64,
}
