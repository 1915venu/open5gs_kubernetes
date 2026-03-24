# PCAP Timing Analysis — 50 UE vs 1000 UE Comparison

---

## Test 1: Baseline (5 Pods × 10 UEs = 50 UEs)

**PCAP:** `amf_attack_preconnect_proof.pcap`

### Pod Barrier Times
| Pod | Barrier Time | Delta |
|---|---|---|
| pod-2 | 18:23:11.**315** | 0 ms |
| pod-0 | 18:23:11.**341** | +26 ms |
| pod-4 | 18:23:11.**350** | +35 ms |
| pod-1 | 18:23:11.**369** | +54 ms |
| pod-3 | 18:23:11.**373** | +58 ms |

### UE Registration Window
| Metric | Value |
|---|---|
| First UE Pkt | 18:23:11.**316** |
| Last UE Pkt | 18:23:11.**418** |
| **Window** | **102 ms** |
| Success | **50/50 (100%)** |

---

## Test 2: Scale Run 1 (20 Pods × 50 UEs = 1000 UEs)
 
**PCAP:** `1000ue_attack.pcap`

### Pod Barrier Times
| Pod | Barrier Time | Delta |
|---|---|---|
| pod-14 | 12:41:16.**064** | 0 ms |
| pod-16 | 12:41:16.**094** | +31 ms |
| pod-10 | 12:41:16.**095** | +31 ms |
| pod-13 | 12:41:16.**117** | +54 ms |
| pod-19 | 12:41:16.**134** | +71 ms |
| pod-15 | 12:41:16.**139** | +76 ms |
| pod-9  | 12:41:16.**142** | +78 ms |
| pod-17 | 12:41:16.**150** | +86 ms |
| pod-18 | 12:41:16.**153** | +90 ms |
| pod-1  | 12:41:16.**755** | +691 ms |
| pod-3  | 12:41:16.**756** | +692 ms |
| pod-2  | 12:41:16.**767** | +704 ms |
| pod-0  | 12:41:16.**785** | +721 ms |
| pod-4  | 12:41:16.**839** | +775 ms |
| pod-5  | 12:41:16.**842** | +778 ms |
| pod-12 | 12:41:16.**948** | +884 ms |
| pod-6  | 12:41:16.**960** | +897 ms |
| pod-7  | 12:41:16.**984** | +920 ms |
| pod-8  | 12:41:17.**015** | +951 ms |
| pod-11 | 12:41:17.**051** | +988 ms |

### UE Registration Window
| Metric | Value |
|---|---|
| First UE Pkt | 12:41:16.**064** |
| Last UE Pkt | 12:41:17.**215** |
| **Window** | **1151 ms** |
| Success | **948/1000 (94.8%)** |

---

## Test 3: Scale Run 2 (20 Pods × 50 UEs = 1000 UEs)
 
**PCAP:** `1000ue_attack_v2.pcap`

### Pod Barrier Times
| Pod | Barrier Time | Delta |
|---|---|---|
| pod-4  | 14:10:59.**336** | 0 ms |
| pod-0  | 14:10:59.**381** | +45 ms |
| pod-2  | 14:10:59.**393** | +57 ms |
| pod-1  | 14:10:59.**403** | +67 ms |
| pod-6  | 14:10:59.**406** | +70 ms |
| pod-3  | 14:10:59.**440** | +104 ms |
| pod-8  | 14:10:59.**633** | +297 ms |
| pod-15 | 14:10:59.**735** | +399 ms |
| pod-5  | 14:10:59.**739** | +403 ms |
| pod-14 | 14:10:59.**748** | +412 ms |
| pod-11 | 14:10:59.**806** | +470 ms |
| pod-17 | 14:10:59.**808** | +472 ms |
| pod-16 | 14:10:59.**809** | +473 ms |
| pod-12 | 14:10:59.**811** | +475 ms |
| pod-19 | 14:10:59.**826** | +490 ms |
| pod-13 | 14:10:59.**838** | +502 ms |
| pod-9  | 14:10:59.**844** | +508 ms |
| pod-7  | 14:10:59.**847** | +511 ms |
| pod-18 | 14:10:59.**871** | +535 ms |
| pod-10 | 14:10:59.**872** | +536 ms |

### UE Registration Window
| Metric | Value |
|---|---|
| First UE Pkt | 14:10:59.**337** |
| Last UE Pkt | 14:11:00.**123** |
| **Window** | **786 ms** |
| Success | **931/1000 (93.1%)** |

---

## Summary Comparison

| Metric | 50 UEs | 1000 UEs (Run 1) | 1000 UEs (Run 2) |
|---|---|---|---|
| Pods | 5 | 20 | 20 |
| UEs/Pod | 10 | 50 | 50 |
| Pod Sync Window | **58 ms** | 988 ms | **536 ms** |
| UE Packet Window | **102 ms** | 1151 ms | **786 ms** |
| Success Rate | **100%** | 94.8% | 93.1% |
| AMF Status | Healthy | Congested | Congested |

> [!NOTE]
> The AMF begins dropping authentication responses at ~930 concurrent registrations.
