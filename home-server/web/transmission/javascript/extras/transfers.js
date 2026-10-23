/**
 * Transfers indicator.
 *
 * Adds a small badge to each finished torrent showing how torrent-finished.rb
 * processed it: filed as TV or a movie, "other" when there was nothing to
 * file, "failed" when handling hit an error, and "not handled" when the
 * torrent completed recently but the script left no record at all.
 *
 * The data comes from /transfers/transfers.json, which the transfers
 * dashboard writes next to its page. Nothing upstream is modified: this file
 * wraps Transmission.prototype.refilter and appends one element per row.
 */
(function () {
    'use strict';

    var DATA_URL = '/transfers/transfers.json';
    var REFRESH_MS = 60 * 1000;
    var DAY = 24 * 60 * 60;

    var LABELS = {
        tv: 'TV',
        movie: 'Movie',
        ebook: 'eBook',
        comic: 'Comic',
        audiobook: 'Audiobook',
        music: 'Music',
        other: 'Other',
        error: 'Failed',
        unhandled: 'Not handled'
    };
    // "other" outcomes that are worth naming on the badge.
    var NAMED_OTHER = { ebook: true, comic: true, audiobook: true, music: true };

    var data = null;
    var loaded = false;

    // The stock UI only fetches hashString for the inspector and never asks
    // for doneDate. Add hashString to the fields fetched when a torrent first
    // appears, and doneDate to the per-refresh fields so it stays current for
    // torrents that finish while the page is open.
    function addField(list, field) {
        if (list && list.indexOf(field) === -1) { list.push(field); }
    }
    if (window.Torrent && Torrent.Fields) {
        addField(Torrent.Fields.Metadata, 'hashString');
        addField(Torrent.Fields.Stats, 'doneDate');
    }

    function load() {
        $.ajax({
            url: DATA_URL,
            dataType: 'json',
            cache: false,
            success: function (d) { data = d; loaded = true; sync(); $(document).trigger('transfers:updated'); },
            error: function () { data = null; loaded = true; sync(); $(document).trigger('transfers:updated'); }
        });
    }

    function recordFor(torrent) {
        if (!data) { return null; }
        var hash = (torrent.getHashString() || '').toLowerCase();
        if (data.by_hash && data.by_hash[hash]) { return data.by_hash[hash]; }
        if (data.by_name && data.by_name[torrent.getName()]) { return data.by_name[torrent.getName()]; }
        return null;
    }

    // What to show for a torrent, or null for nothing.
    function classify(torrent, now) {
        var record = recordFor(torrent);
        if (record) {
            var status = record.status === 'warning' ? 'other' : record.status;
            var kind = status;
            if (status === 'ok' || (status === 'other' && NAMED_OTHER[record.outcome])) { kind = record.outcome; }
            var title = record.message || '';
            if (record.destination) { title += '\n' + record.destination; }
            if (record.file_command) { title += '\nClick to copy the command that files it.'; }
            return { kind: kind, status: status, text: LABELS[kind] || kind, title: title, command: record.file_command || null };
        }
        if (!data || torrent.getPercentDone() < 1) { return null; }
        var windowDays = data.unhandled_window_days || 7;
        var doneAt = torrent.fields.doneDate || now; // completed since the page loaded
        if (now - doneAt > windowDays * DAY) { return null; }
        return {
            kind: 'unhandled',
            status: 'unhandled',
            text: LABELS.unhandled,
            title: 'Finished, but torrent-finished.sh left no record. Check ~/logs/torrent-finished.out.'
        };
    }

    // Copies text; the page is plain HTTP, where navigator.clipboard is
    // unavailable, so select-and-copy comes first. Returns true on success.
    function copyText(text) {
        try {
            var area = document.createElement('textarea');
            area.value = text;
            area.setAttribute('readonly', '');
            area.style.position = 'fixed';
            area.style.top = '-1000px';
            document.body.appendChild(area);
            area.select();
            area.setSelectionRange(0, text.length);
            var ok = document.execCommand('copy');
            document.body.removeChild(area);
            if (ok) { return true; }
        } catch (e) { /* fall through */ }
        if (navigator.clipboard) { navigator.clipboard.writeText(text); return true; }
        return false;
    }

    function badgeFor(element) {
        var badge = element._transfer_badge;
        if (!badge) {
            badge = document.createElement('a');
            badge.className = 'transfer_badge';
            badge.target = '_blank';
            badge.rel = 'noopener';
            // Keep the click from selecting or toggling the row underneath.
            $(badge).on('dblclick mousedown', function (e) { e.stopPropagation(); });
            $(badge).on('click', function (e) {
                e.stopPropagation();
                if (!badge._command) { return; } // plain link to the dashboard
                e.preventDefault();
                var label = badge.textContent;
                badge.textContent = copyText(badge._command) ? 'Copied' : 'Copy failed';
                setTimeout(function () { badge.textContent = label; }, 1500);
            });
            element.appendChild(badge);
            element._transfer_badge = badge;
        }
        return badge;
    }

    function sync() {
        var tr = window.transmission;
        if (!loaded || !tr || !tr._rows) { return; }
        var now = Math.floor(Date.now() / 1000);
        for (var i = 0, row; (row = tr._rows[i]); ++i) {
            var element = row.getElement();
            var info = classify(row.getTorrent(), now);
            if (!info) {
                if (element._transfer_badge) { element._transfer_badge.style.display = 'none'; }
                continue;
            }
            var badge = badgeFor(element);
            badge.style.display = '';
            badge.className = 'transfer_badge ' + info.kind;
            if (badge.textContent !== 'Copied' && badge.textContent !== 'Copy failed') { badge.textContent = info.text; }
            badge.title = info.title;
            badge.href = (data && data.dashboard_url) || '/transfers/';
            badge._command = info.command;
        }
    }

    // Re-badge whenever the list is rebuilt or refiltered.
    if (window.Transmission && Transmission.prototype.refilter) {
        var refilter = Transmission.prototype.refilter;
        Transmission.prototype.refilter = function () {
            var result = refilter.apply(this, arguments);
            sync();
            return result;
        };
    }

    // For other extras (filters.js): how a torrent was handled, or null.
    window.TransfersExtra = {
        classify: function (torrent) { return classify(torrent, Math.floor(Date.now() / 1000)); },
        hasRecord: function (torrent) { return recordFor(torrent) !== null; },
        isLoaded: function () { return loaded; }
    };

    // A footer button to the transfers dashboard, next to upstream's buttons.
    function addDashboardButton() {
        var footer = $('div.torrent_footer');
        if (!footer.length || document.getElementById('dashboard-button')) { return; }
        var button = document.createElement('a');
        button.id = 'dashboard-button';
        button.className = 'extra-footer-button';
        button.href = '/transfers/';
        button.target = '_blank';
        button.rel = 'noopener';
        button.title = 'Transfers dashboard';
        button.textContent = '\u25A4'; // ▤
        var after = $('#theme-button');
        (after.length ? after : $('#compact-button')).after(button);
    }

    function updateDashboardButton() {
        var button = document.getElementById('dashboard-button');
        if (button && data && data.dashboard_url) { button.href = data.dashboard_url; }
    }

    $(function () {
        addDashboardButton();
        $(document).on('transfers:updated', updateDashboardButton);
        load();
        setInterval(load, REFRESH_MS);
        setInterval(sync, 5000); // catches rows updated in place between refilters
    });
})();
