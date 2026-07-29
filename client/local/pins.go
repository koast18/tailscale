// Copyright (c) Tailscale Inc & contributors
// SPDX-License-Identifier: BSD-3-Clause

//go:build !ts_omit_pinning

package local

import (
	"context"
	"net/http"

	"tailscale.com/feature/pinning/pins"
)

// GetPins returns the current profile's locally-pinned favorites.
//
// API maturity: this method is not considered a stable API and is subject to change between releases.
func (lc *Client) GetPins(ctx context.Context) (pins.Set, error) {
	body, err := lc.get200(ctx, "/localapi/v0/pins")
	if err != nil {
		return pins.Set{}, err
	}
	return decodeJSON[pins.Set](body)
}

// SetPins replaces the categories named in req for the current profile and returns the full updated
// pinned favorites.
//
// API maturity: this method is not considered a stable API and is subject to change between releases.
func (lc *Client) SetPins(ctx context.Context, req pins.SetRequest) (pins.Set, error) {
	body, err := lc.send(ctx, "POST", "/localapi/v0/pins", http.StatusOK, jsonBody(req))
	if err != nil {
		return pins.Set{}, err
	}
	return decodeJSON[pins.Set](body)
}
