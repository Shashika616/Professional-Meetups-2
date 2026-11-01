package wallet

import "testing"

func TestAllowedAfter(t *testing.T) {
	want := []int64{60, 54, 48, 42, 36, 30, 24, 18, 12, 6, 0, 0}
	for k, w := range want {
		if got := AllowedAfter(60, 10, k); got != w {
			t.Errorf("AllowedAfter(60, 10, %d) = %d, want %d", k, got, w)
		}
	}
	// Rounding: 7 credits at 10% loses floor(0.7k), cumulatively.
	for k, w := range []int64{7, 7, 6, 5, 5, 4, 3, 3, 2, 1, 0} {
		if got := AllowedAfter(7, 10, k); got != w {
			t.Errorf("AllowedAfter(7, 10, %d) = %d, want %d", k, got, w)
		}
	}
	if MaxPeriods(10) != 10 || MaxPeriods(30) != 4 || MaxPeriods(100) != 1 {
		t.Errorf("MaxPeriods wrong: %d %d %d", MaxPeriods(10), MaxPeriods(30), MaxPeriods(100))
	}
	for _, p := range []int{1, 3, 7, 10, 30, 33, 100} {
		if AllowedAfter(97, p, MaxPeriods(p)) != 0 {
			t.Errorf("a lot decaying %d%% is not empty after MaxPeriods", p)
		}
	}
}
