package com.superology;

import java.util.*;
import org.apache.kafka.clients.consumer.*;
import org.apache.kafka.common.*;

final class Commits {
  HashMap<TopicPartition, OffsetAndMetadata> pendingCommits = new HashMap<TopicPartition, OffsetAndMetadata>();
  KafkaConsumer<String, byte[]> consumer;
  long commitIntervalNs;
  long lastCommit;

  public Commits(KafkaConsumer<String, byte[]> consumer, long commitIntervalMs) {
    this.consumer = consumer;
    this.commitIntervalNs = java.time.Duration.ofMillis(commitIntervalMs).toNanos();
    this.lastCommit = System.nanoTime() - commitIntervalNs;
  }

  public void add(TopicPartition topicPartition, long offset) {
    pendingCommits.put(topicPartition, new OffsetAndMetadata(offset + 1));
  }

  public void flush() {
    var now = System.nanoTime();
    if (now - lastCommit >= commitIntervalNs) {
      pendingCommits.keySet().retainAll(consumer.assignment());
      if (!pendingCommits.isEmpty()) {
        consumer.commitAsync(pendingCommits, null);
        pendingCommits.clear();
        lastCommit = now;
      }
    }
  }
}
