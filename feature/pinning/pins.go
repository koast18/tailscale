// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

package pinning

import (
	"encoding/json"
	"errors"

	"tailscale.com/feature/pinning/pins"
	"tailscale.com/ipn"
)

// pinsFor returns the saved pinned favorites for the current profile, or a zero [pins.Set] when
// none are saved or there's no current profile.
func (e *extension) pinsFor() (pins.Set, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.loadLocked()
}

// setPins replaces the categories in req whose Set field is true, leaves the rest untouched, and
// returns the full updated [pins.Set].
func (e *extension) setPins(req pins.SetRequest) (pins.Set, error) {
	// Hold mu across the whole read-modify-write; each write persists the full value, so
	// concurrent writers would otherwise clobber each other.
	e.mu.Lock()
	defer e.mu.Unlock()

	cur, err := e.loadLocked()
	if err != nil {
		return pins.Set{}, err
	}

	if req.DevicesSet {
		cur.Devices = req.Pins.Devices
	}
	if req.ExitNodesSet {
		cur.ExitNodes = req.Pins.ExitNodes
	}
	if req.ServicesSet {
		cur.Services = req.Pins.Services
	}

	if err := e.saveLocked(cur); err != nil {
		return pins.Set{}, err
	}
	return cur, nil
}

// loadLocked reads the current profile's pins, returning a zero [pins.Set] when there's no store or
// nothing saved yet. The caller must hold e.mu.
func (e *extension) loadLocked() (pins.Set, error) {
	if e.store == nil {
		return pins.Set{}, nil
	}
	data, err := e.store.ReadState(featureName)
	if errors.Is(err, ipn.ErrStateNotExist) {
		return pins.Set{}, nil
	}
	if err != nil {
		return pins.Set{}, err
	}
	var set pins.Set
	if err := json.Unmarshal(data, &set); err != nil {
		return pins.Set{}, err
	}
	return set, nil
}

// saveLocked writes set to the current profile's store, erroring when there's no store to persist
// to. The caller must hold e.mu.
func (e *extension) saveLocked(set pins.Set) error {
	if e.store == nil {
		return errors.New("no store available to persist pinned favorites")
	}
	data, err := json.Marshal(set)
	if err != nil {
		return err
	}
	return e.store.WriteState(featureName, data)
}
