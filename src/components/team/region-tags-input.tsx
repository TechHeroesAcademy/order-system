"use client";

import { useId, useState } from "react";
import { X } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { RegionDatalist } from "@/components/shared/region-datalist";
import type { Region } from "@/types/database";

/**
 * A driver's covered areas — typed by keyboard, not ticked from a checkbox
 * list (migration 0025): type a name and press Enter (or ",") to add it as
 * a chip, remove one with its ×. Existing region names are suggested via a
 * <datalist> as you type, but a brand-new name isn't blocked — it's
 * resolved/auto-created server-side by find_or_create_region() on save, so
 * this stays "written by keyboard" end to end rather than secretly
 * requiring an Owner to add the area first.
 */
export function RegionTagsInput({
  value,
  onChange,
  regions,
  placeholder = "اكتب اسم المنطقة ثم Enter",
}: {
  value: string[];
  onChange: (names: string[]) => void;
  regions: Region[];
  placeholder?: string;
}) {
  const listId = useId();
  const [draft, setDraft] = useState("");

  function commit() {
    const name = draft.trim().replace(/\s+/g, " ");
    setDraft("");
    if (name.length < 2) return;
    if (!value.includes(name)) {
      onChange([...value, name]);
    }
  }

  function remove(name: string) {
    onChange(value.filter((v) => v !== name));
  }

  return (
    <div className="space-y-2">
      {value.length > 0 && (
        <div className="flex flex-wrap gap-1.5">
          {value.map((name) => (
            <Badge key={name} variant="outline" className="gap-1 py-1 ps-2.5">
              {name}
              <button
                type="button"
                onClick={() => remove(name)}
                className="rounded-full p-0.5 hover:bg-destructive/10 hover:text-destructive"
                aria-label={`إزالة ${name}`}
              >
                <X className="size-3" />
              </button>
            </Badge>
          ))}
        </div>
      )}
      <Input
        list={listId}
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === ",") {
            e.preventDefault();
            commit();
          }
        }}
        onBlur={commit}
        placeholder={placeholder}
      />
      <RegionDatalist id={listId} regions={regions} />
      <p className="text-xs text-muted-foreground">منطقة جديدة تُنشأ تلقائيًا عند إضافتها لأول مرة.</p>
    </div>
  );
}
