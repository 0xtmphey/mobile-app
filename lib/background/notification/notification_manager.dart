
import 'dart:convert';
import 'dart:io';

import 'package:cobble/domain/db/dao/active_notification_dao.dart';
import 'package:cobble/domain/db/dao/notification_channel_dao.dart';
import 'package:cobble/domain/db/models/active_notification.dart';
import 'package:cobble/domain/db/models/notification_channel.dart';
import 'package:cobble/domain/db/models/timeline_pin.dart';
import 'package:cobble/domain/db/models/timeline_pin_layout.dart';
import 'package:cobble/domain/db/models/timeline_pin_type.dart';
import 'package:cobble/domain/notification/notification_action.dart';
import 'package:cobble/domain/notification/notification_category_android.dart';
import 'package:cobble/domain/notification/notification_message.dart';
import 'package:cobble/domain/preferences.dart';
import 'package:cobble/domain/timeline/timeline_action.dart';
import 'package:cobble/domain/timeline/timeline_action_response.dart';
import 'package:cobble/domain/timeline/timeline_attribute.dart';
import 'package:cobble/domain/timeline/timeline_icon.dart';
import 'package:cobble/domain/timeline/timeline_serializer.dart';
import 'package:cobble/infrastructure/datasources/preferences.dart';
import 'package:cobble/infrastructure/pigeons/pigeons.g.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid_type/uuid_type.dart';

final Uuid notificationsWatchappId = Uuid.parse("B2CAE818-10F8-46DF-AD2B-98AD2254A3C1");

class NotificationManager {
  final NotificationUtils _notificationUtils = NotificationUtils();
  final ActiveNotificationDao _activeNotificationDao;
  final NotificationChannelDao _notificationChannelDao;
  final Future<SharedPreferences> _preferencesFuture;

  NotificationManager(this._activeNotificationDao, this._notificationChannelDao, this._preferencesFuture);

  Future<TimelineIcon> _determineIcon(String? packageId, CategoryAndroid? category) async {
    TimelineIcon icon = TimelineIcon.notificationGeneric;
    if (Platform.isAndroid) {
      if (category != null) icon = category.icon;

      switch (packageId) {
        case "com.google.android.gm.lite":
        case "com.google.android.gm":
          icon = TimelineIcon.notificationGmail;
          break;
        case "com.microsoft.office.outlook":
          icon = TimelineIcon.notificationOutlook;
          break;
        case "com.Slack":
          icon = TimelineIcon.notificationSlack;
          break;
        case "com.snapchat.android":
          icon = TimelineIcon.notificationSnapchat;
          break;
        case "com.twitter.android":
        case "com.twitter.android.lite":
          icon = TimelineIcon.notificationTwitter;
          break;
        case "org.telegram.messenger":
          icon = TimelineIcon.notificationTelegram;
          break;
        case "com.facebook.katana":
        case "com.facebook.lite":
          icon = TimelineIcon.notificationFacebook;
          break;
        case "com.facebook.orca":
          icon = TimelineIcon.notificationFacebookMessenger;
          break;
        case "com.whatsapp":
        case "com.whatsapp.w4b":
          icon = TimelineIcon.notificationWhatsapp;
          break;
      }
    }
    return icon;
  }

  Future<TimelinePin> handleNotification(NotificationPigeon notif) async {
    final prefs = Preferences(await _preferencesFuture);
    if (prefs.getDefaultMutedPackagesVersion() != defaultMutedPackagesVersion) {
      final current = prefs.getNotificationsMutedPackages();
      await prefs.setNotificationsMutedPackages((current + defaultMutedPackages).toSet().toList());
    }

    NotificationChannel? channel = await _notificationChannelDao.getNotifChannelByIds(notif.tagId!, notif.packageId!);
    if (channel == null) {
      _notificationChannelDao.insertOrUpdateNotificationChannel(NotificationChannel(notif.packageId!, notif.tagId!, true));
    }

    ActiveNotification? old = await _activeNotificationDao.getActiveNotifByNotifMeta(notif.notifId, notif.packageId, notif.tagId);
    if (old != null && old.pinId != null && notif.messagesJson?.isEmpty != false) {
      StringWrapper id = StringWrapper();
      id.value = old.pinId.toString();
      _notificationUtils.dismissNotificationWatch(id);
    }
    Uuid itemId = RandomUuidGenerator().generate();
    List<TimelineAttribute> attributes = [
      TimelineAttribute.tinyIcon(await _determineIcon(notif.packageId, CategoryAndroid.fromId(notif.category))),
      TimelineAttribute.title(notif.appName!.trim()),
    ];
    TimelineAttribute subtitle = TimelineAttribute.subtitle(notif.title!.trim());
    TimelineAttribute content = TimelineAttribute.body(notif.text!.trim());

    if (jsonDecode(notif.messagesJson ?? "[]").isNotEmpty) {
      List<Map<String, dynamic>> messages = List<Map<String, dynamic>>.from(jsonDecode(notif.messagesJson!));
      content = TimelineAttribute.body(NotificationMessage.fromJson(messages.last).text!.trim());
    }

    List<TimelineAction> actions = [];
    actions.add(TimelineAction(META_ACTION_DISMISS, actionTypeGeneric, [
      TimelineAttribute.title("Dismiss")
    ]));

    //TODO: change to use preferences datasource
    List<String>? disabledActionPkgs = (await _preferencesFuture).getStringList(disabledActionPackagesKey);
    if (disabledActionPkgs == null || !disabledActionPkgs.contains(notif.packageId)) {
      List<Map<String, dynamic> > notifActions = List<Map<String, dynamic>>.from(jsonDecode(notif.actionsJson!));
      for (int i=0; i<notifActions.length; i++) {
        NotificationAction action = NotificationAction.fromJson(notifActions[i]);
        actions.add(TimelineAction((META_ACTION_LENGTH)+i, action.isResponse! ? actionTypeResponse : actionTypeGeneric, [
          TimelineAttribute.title(action.title)
        ]));
      }
    }
    attributes.add(subtitle);
    attributes.add(content);

    if (Platform.isAndroid && notif.color != 0 && notif.color != 1) {
      attributes.add(TimelineAttribute.primaryColor(Color(notif.color!)));
    }

    actions.add(TimelineAction(META_ACTION_OPEN, actionTypeGeneric, [
      TimelineAttribute.title("Open on phone")
    ]));
    actions.add(TimelineAction(META_ACTION_MUTE_PKG, actionTypeGeneric, [
      TimelineAttribute.title("Mute app")
    ]));
    if (notif.tagId != null) {
      final channel = await _notificationChannelDao.getNotifChannelByIds(notif.tagId!, notif.packageId!);
      actions.add(TimelineAction(META_ACTION_MUTE_TAG, actionTypeGeneric, [
        TimelineAttribute.title("Mute tag\n'${channel?.name ?? notif.tagId}'")
      ]));
    }

    _activeNotificationDao.insertOrUpdateActiveNotification(ActiveNotification(pinId: itemId, packageId: notif.packageId, notifId: notif.notifId, tagId: notif.tagId));

    return TimelinePin(
      itemId: itemId,
      parentId: notificationsWatchappId,
      timestamp: DateTime.now(),
      duration: 0,
      type: TimelinePinType.notification,
      layout: TimelinePinLayout.genericNotification,
      attributesJson: serializeAttributesToJson(attributes),
      actionsJson: serializeActionsToJson(actions),

      isAllDay: false,
      isVisible: true,
      isFloating: false,
      persistQuickView: false
    );
  }

  Future<TimelineActionResponse?> handleNotifAction(ActionTrigger trigger) async {
    Preferences prefs = Preferences(await _preferencesFuture);
    
    TimelineActionResponse? ret;
    switch (trigger.actionId) {
      case META_ACTION_DISMISS:
        BooleanWrapper res = await _notificationUtils.dismissNotification(StringWrapper()..value=trigger.itemId.toString());
        if (res.value!) {
          ret = TimelineActionResponse(true, attributes: [
            TimelineAttribute.subtitle("Dismissed"),
            TimelineAttribute.largeIcon(TimelineIcon.resultDismissed)
          ]);
        }
        break;
      case META_ACTION_OPEN:
        await _notificationUtils.openNotification(StringWrapper()..value=trigger.itemId.toString());
        ret = TimelineActionResponse(true, attributes: [
          TimelineAttribute.subtitle("Opened on phone"),
          TimelineAttribute.largeIcon(TimelineIcon.genericConfirmation)
        ]);
        break;
      case META_ACTION_MUTE_PKG:
        List<String?> muted = prefs.getNotificationsMutedPackages()!;
        ActiveNotification? notif = await _activeNotificationDao.getActiveNotifByPinId(Uuid.parse(trigger.itemId!));
        if (notif != null) {
          await prefs.setNotificationsMutedPackages(muted + [notif.packageId]);
          ret = TimelineActionResponse(true, attributes: [
            TimelineAttribute.subtitle("Muted app"),
            TimelineAttribute.largeIcon(TimelineIcon.resultMute)
          ]);
        }
        break;
      case META_ACTION_MUTE_TAG:
        ActiveNotification? notif = await _activeNotificationDao.getActiveNotifByPinId(Uuid.parse(trigger.itemId!));
        if (notif != null) {
          await _notificationChannelDao.insertOrUpdateNotificationChannel(NotificationChannel(notif.packageId!, notif.tagId!, false));
          ret = TimelineActionResponse(true, attributes: [
            TimelineAttribute.subtitle("Muted channel"),
            TimelineAttribute.largeIcon(TimelineIcon.resultMute)
          ]);
        }
        break;
      default: // Custom
        List<TimelineAttribute> attrs = [];
        if (trigger.attributesJson != null && trigger.attributesJson!.isNotEmpty) {
          List<Map<String, dynamic>> attrsJson = new List<Map<String, dynamic>>.from(jsonDecode(trigger.attributesJson!));
          attrsJson.forEach((el) {
            attrs.add(TimelineAttribute.fromJson(el));
          });
        }
        String? responseText = attrs.firstWhere((el) => el.id == 1, orElse: ()=>TimelineAttribute(string: "")).string;
        await _notificationUtils.executeAction(
            NotifActionExecuteReq()
          ..itemId=trigger.itemId.toString()
          ..actionId=trigger.actionId!-META_ACTION_LENGTH
          ..responseText=responseText
        );

        ret = TimelineActionResponse(true, attributes: [
          TimelineAttribute.subtitle("Done"),
          TimelineAttribute.largeIcon((responseText?.isEmpty ?? true) ? TimelineIcon.genericConfirmation : TimelineIcon.resultSent)
        ]);
        break;
    }
    return ret;
  }

  void dismissNotification(Uuid itemId) {
    _notificationUtils.dismissNotification(StringWrapper()..value=itemId.toString());
    _activeNotificationDao.delete(itemId);
  }
}

final notificationManagerProvider = Provider<NotificationManager>((ref) => NotificationManager(ref.read(activeNotifDaoProvider), ref.read(notifChannelDaoProvider), ref.read(sharedPreferencesProvider)));

final disabledActionPackagesKey = "disabledActionPackages";

const int META_ACTION_DISMISS = 0;
const int META_ACTION_OPEN = 1;
const int META_ACTION_MUTE_PKG = 2;
const int META_ACTION_MUTE_TAG = 3;
const int META_ACTION_LENGTH = 4;
