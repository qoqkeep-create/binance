from decimal import Decimal, InvalidOperation

from django.db import transaction
from rest_framework import serializers
from rest_framework.views import APIView

from common.response import fail, ok
from common.request import request_data_mapping
from trading.models import Strategy, StrategyLevel


class StrategyLevelInputSerializer(serializers.Serializer):
    profitRR = serializers.FloatField()
    reducePosition = serializers.FloatField(min_value=0)
    stopLossType = serializers.ChoiceField(choices=["none", "fixedRR", "absoluteRR"])
    stopLossRR = serializers.FloatField(required=False, allow_null=True)
    stopLossAbsoluteRR = serializers.FloatField(required=False, allow_null=True)

    def validate(self, attrs):
        stop_loss_type = attrs.get("stopLossType")
        stop_loss_rr = attrs.get("stopLossRR")
        stop_loss_absolute_rr = attrs.get("stopLossAbsoluteRR")

        if stop_loss_type == "none":
            attrs["stopLossRR"] = None
            attrs["stopLossAbsoluteRR"] = None
            return attrs

        if stop_loss_type == "fixedRR":
            if stop_loss_rr is None or Decimal(str(stop_loss_rr)) <= 0:
                raise serializers.ValidationError("选择“移动到当前浮盈-xR”时，x 必须大于 0")
            attrs["stopLossAbsoluteRR"] = None
            return attrs

        if stop_loss_type == "absoluteRR":
            if stop_loss_absolute_rr is None or Decimal(str(stop_loss_absolute_rr)) <= Decimal("-1"):
                raise serializers.ValidationError("选择“移动到xR位置”时，x 必须大于 -1")
            attrs["stopLossRR"] = None
            return attrs

        return attrs


class StrategySaveSerializer(serializers.Serializer):
    strategy_id = serializers.IntegerField(required=False)
    name = serializers.CharField(max_length=100)
    levels = StrategyLevelInputSerializer(many=True)

    def validate(self, attrs):
        levels = attrs.get("levels") or []
        if not levels:
            raise serializers.ValidationError("至少需要一个层级")
        if len(levels) > 5:
            raise serializers.ValidationError("最多5个层级")

        reduce_sum = Decimal("0")
        last_profit = Decimal("-1")
        for idx, level in enumerate(levels, start=1):
            try:
                profit = Decimal(str(level["profitRR"]))
                reduce = Decimal(str(level["reducePosition"]))
            except (InvalidOperation, TypeError, ValueError):
                raise serializers.ValidationError("策略参数格式错误")
            if profit <= 0:
                raise serializers.ValidationError(f"L{idx} 的盈利数值必须大于0")
            if profit <= last_profit:
                raise serializers.ValidationError(f"L{idx} 的盈利数值必须大于上一层")
            last_profit = profit
            reduce_sum += reduce

        if reduce_sum > Decimal("100"):
            raise serializers.ValidationError("减仓总和不能超过100%")
        return attrs


def _serialize_strategy(strategy: Strategy) -> dict:
    levels = strategy.levels.all()
    return {
        "id": strategy.id,
        "name": strategy.name,
        "is_active": strategy.is_active,
        "levels": [
            {
                "profitRR": float(level.profit_rr),
                "reducePosition": float(level.reduce_position),
                "stopLossType": level.stop_loss_type,
                "stopLossRR": float(level.stop_loss_rr) if level.stop_loss_rr is not None else None,
                "stopLossAbsoluteRR": float(level.stop_loss_absolute_rr) if level.stop_loss_absolute_rr is not None else None,
            }
            for level in levels
        ],
    }


class StrategyListView(APIView):
    def get(self, request):
        strategies = Strategy.objects.filter(user=request.user).prefetch_related("levels")
        return ok(data=[_serialize_strategy(item) for item in strategies])


class StrategySaveView(APIView):
    def post(self, request):
        serializer = StrategySaveSerializer(data=request.data)
        if not serializer.is_valid():
            errors = serializer.errors
            first_key = next(iter(errors.keys()), None)
            if first_key and errors[first_key]:
                return fail(str(errors[first_key][0]))
            return fail("请求参数错误")

        data = serializer.validated_data
        strategy_id = data.get("strategy_id")

        with transaction.atomic():
            if strategy_id:
                strategy = Strategy.objects.filter(id=strategy_id, user=request.user).first()
                if not strategy:
                    return fail("策略不存在")
                strategy.name = data["name"].strip()
                strategy.save(update_fields=["name", "updated_at"])
                StrategyLevel.objects.filter(strategy=strategy).delete()
            else:
                strategy = Strategy.objects.create(user=request.user, name=data["name"].strip())

            levels_to_create = []
            for idx, level in enumerate(data["levels"], start=1):
                levels_to_create.append(
                    StrategyLevel(
                        strategy=strategy,
                        sort_order=idx,
                        profit_rr=Decimal(str(level["profitRR"])),
                        reduce_position=Decimal(str(level["reducePosition"])),
                        stop_loss_type=level["stopLossType"],
                        stop_loss_rr=(
                            Decimal(str(level["stopLossRR"]))
                            if level.get("stopLossRR") is not None
                            else None
                        ),
                        stop_loss_absolute_rr=(
                            Decimal(str(level["stopLossAbsoluteRR"]))
                            if level.get("stopLossAbsoluteRR") is not None
                            else None
                        ),
                    )
                )
            StrategyLevel.objects.bulk_create(levels_to_create)

        strategy = Strategy.objects.filter(id=strategy.id).prefetch_related("levels").first()
        return ok(message="保存成功", data=_serialize_strategy(strategy))


class StrategyDeleteView(APIView):
    def post(self, request):
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        strategy_id = payload.get("strategy_id")
        if not strategy_id:
            return fail("strategy_id不能为空")
        strategy = Strategy.objects.filter(id=strategy_id, user=request.user).first()
        if not strategy:
            return fail("策略不存在")
        strategy.delete()
        return ok(message="删除成功")


class StrategySetActiveView(APIView):
    def post(self, request):
        payload = request_data_mapping(request)
        if payload is None:
            return fail("请求参数必须是对象")
        if payload.get("manual") is True:
            Strategy.objects.filter(user=request.user, is_active=True).update(is_active=False)
            return ok(message="后续开仓使用手动止盈")
        strategy_id = payload.get("strategy_id")
        if not strategy_id:
            return fail("strategy_id不能为空")
        strategy = Strategy.objects.filter(id=strategy_id, user=request.user).first()
        if not strategy:
            return fail("策略不存在")

        with transaction.atomic():
            Strategy.objects.filter(user=request.user, is_active=True).update(is_active=False)
            strategy.is_active = True
            strategy.save(update_fields=["is_active", "updated_at"])
        return ok(message="策略已设为当前使用")
