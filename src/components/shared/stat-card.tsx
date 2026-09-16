import type { LucideIcon } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { cn } from "@/lib/utils";

export function StatCard({
  label,
  value,
  icon: Icon,
  tone = "default",
}: {
  label: string;
  value: string | number;
  icon?: LucideIcon;
  tone?: "default" | "warning" | "destructive" | "success";
}) {
  const toneClass = {
    default: "text-foreground",
    warning: "text-warning",
    destructive: "text-destructive",
    success: "text-success",
  }[tone];

  return (
    <Card className="group transition-[transform,box-shadow] duration-200 hover:-translate-y-0.5 hover:shadow-md">
      <CardContent className="flex items-center justify-between gap-3 py-4">
        <div>
          <p className="text-sm text-muted-foreground">{label}</p>
          <p className={cn("text-2xl font-bold tabular-nums", toneClass)}>{value}</p>
        </div>
        {Icon && (
          <Icon
            className={cn(
              "size-8 opacity-70 transition-transform duration-200 group-hover:scale-110 group-hover:opacity-90",
              toneClass,
            )}
          />
        )}
      </CardContent>
    </Card>
  );
}
